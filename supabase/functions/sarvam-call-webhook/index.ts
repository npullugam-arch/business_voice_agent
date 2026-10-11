import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {createClient} from "jsr:@supabase/supabase-js@2";
import {json} from "../_shared/http.ts";
import {pickupSummary} from "../_shared/pickup-summary.ts";

const TERMINAL=new Set(["completed","no_answer","busy","failed"]);
const OUTCOMES=new Set(["confirmed","tentative","no_answer","busy","rejected","wrong_number","callback_requested","already_collected_reported","do_not_call","failed"]);

Deno.serve(async(req)=>{
  if(req.method!=="POST")return json({ok:false},405);
  const expected=Deno.env.get("SARVAM_WEBHOOK_SECRET")||"",actual=new URL(req.url).searchParams.get("token")||"";
  if(!expected||!safeEqual(expected,actual))return json({ok:false},401);
  const admin=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  try{
    const p=await req.json(),attemptId=text(p.attempt_id,200);
    const status=terminalStatus(p);
    if(!attemptId||!status||!TERMINAL.has(status))return json({ok:false,message:"Unsupported webhook payload"},400);
    const {data:log,error:findError}=await admin.from("call_logs").select("id,order_id,customer_id,provider_attempt_id").eq("provider","sarvam").eq("provider_attempt_id",attemptId).maybeSingle();
    if(findError)throw findError;if(!log)return json({ok:false},404);
    if(!correlates(p,log))return json({ok:false,message:"Webhook metadata mismatch"},409);

    const vars=(p.output_agent_variables&&typeof p.output_agent_variables==="object"?p.output_agent_variables:p.final_agent_variables)||{};
    const providerTranscript=cleanTranscript(p.interaction_transcript);
    const interactionId=text(p.interaction_id,500);
    const originalTelugu=providerTranscript?.length&&providerTranscript.every(turn=>telugu(turn.indic_text))?providerTranscript.map(turn=>({role:turn.role,text:turn.indic_text})):null;
    const outcome=outcomeValue(vars.call_outcome,status);
    const customerResponse=text(vars.customer_response,2000),summary=text(vars.customer_summary_te,2000);
    const shortReply=pickupSummary(providerTranscript,summary,customerResponse);
    const result={status,interaction_id:interactionId,call_outcome:outcome,started_at:dateTime(p.start_datetime),completed_at:dateTime(p.end_datetime),executed_at:dateTime(p.executed_at),duration_seconds:duration(p.duration),provider_transcript:providerTranscript,telugu_transcript:originalTelugu,transcript_kind:originalTelugu?"original_telugu":providerTranscript?"provider_english":"unavailable",customer_response:customerResponse,customer_response_te:shortReply,customer_summary_te:shortReply,pickup_date:isoDate(vars.pickup_date),pickup_time:isoTime(vars.pickup_time),pickup_period:period(vars.pickup_time_period),follow_up_required:truthy(vars.follow_up_required),callback_requested:truthy(vars.callback_requested),callback_date:isoDate(vars.callback_date),do_not_call:truthy(vars.do_not_call),failure_reason:text(p.failure_reason,500),recording_available:false,recording_provider_ref:null,recording_content_type:null,raw_payload:redact(p)};
    const {data:applied,error}=await admin.rpc("apply_sarvam_call_result",{p_attempt_id:attemptId,p_result:result});
    if(error)throw error;if(!applied)return json({ok:false},404);
    if(providerTranscript||interactionId)EdgeRuntime.waitUntil(enrich(admin,log.id,providerTranscript,interactionId));
    return json({ok:true});
  }catch(e){console.error("sarvam-webhook",e instanceof Error?e.message:"unknown");return json({ok:false},500)}
});

function terminalStatus(p:any){const direct=p.status,connectivity=p.connectivity_status,completion=p.completion_status;if(direct==="connected"||connectivity==="connected"||completion==="completed"||completion==="partial")return "completed";if(["no_answer","busy"].includes(direct))return direct;if(["no_answer","busy"].includes(connectivity))return connectivity;if(direct==="failed"||connectivity==="failed"||completion==="failed")return "failed";return null}
function correlates(p:any,log:any){const m=p?.webhook_config?.metadata||p?.metadata;if(!m||typeof m!=="object")return true;return (!m.order_id||m.order_id===log.order_id)&&(!m.customer_id||m.customer_id===log.customer_id)}
function cleanTranscript(value:unknown){if(!Array.isArray(value))return null;const turns=value.map((turn:any)=>({role:turn?.role==="agent"?"agent":turn?.role==="user"?"user":null,en_text:text(turn?.en_text,4000),indic_text:text(turn?.indic_text,4000)})).filter(turn=>turn.role&&(turn.en_text||turn.indic_text));return turns.length?turns:null}
async function teluguTranscript(turns:any[]|null){if(!turns)return{turns:null,kind:"unavailable"};if(turns.every(t=>telugu(t.indic_text)))return{turns:turns.map(t=>({role:t.role,text:t.indic_text})),kind:"original_telugu"};const key=Deno.env.get("SARVAM_TRANSLATION_API_KEY")||Deno.env.get("SARVAM_API_KEY");if(!key)return{turns:null,kind:"provider_english"};try{const converted=await Promise.all(turns.map(async turn=>{if(telugu(turn.indic_text))return{role:turn.role,text:turn.indic_text};if(!turn.en_text)return null;const res=await fetch("https://api.sarvam.ai/translate",{method:"POST",headers:{"api-subscription-key":key,"Content-Type":"application/json"},body:JSON.stringify({input:turn.en_text,source_language_code:"en-IN",target_language_code:"te-IN",model:"sarvam-translate:v1"})});if(!res.ok)throw new Error(`translation_${res.status}`);const body=await res.json();return typeof body.translated_text==="string"?{role:turn.role,text:body.translated_text}:null}));return{turns:converted.filter(Boolean),kind:"provider_english_translated"}}catch(e){console.warn("Transcript translation unavailable",e instanceof Error?e.message:"unknown");return{turns:null,kind:"provider_english"}}}
async function recordingMetadata(interactionId:string){try{const res=await fetch(analyticsUrl("recordings",interactionId),{headers:{"X-API-Key":Deno.env.get("SARVAM_API_KEY")!}});if(!res.ok)return{available:false,contentType:null};await res.body?.cancel();return{available:true,contentType:res.headers.get("Content-Type")}}catch{return{available:false,contentType:null}}}
async function recordingMetadataWithRetry(interactionId:string){let result={available:false,contentType:null as string|null};for(let attempt=0;attempt<5;attempt++){result=await recordingMetadata(interactionId);if(result.available)return result;if(attempt<4)await new Promise(resolve=>setTimeout(resolve,4000))}return result}
async function enrich(admin:any,logId:string,transcript:any[]|null,interactionId:string|null){try{const [translated,recording]=await Promise.all([teluguTranscript(transcript),interactionId?recordingMetadataWithRetry(interactionId):Promise.resolve({available:false,contentType:null})]);const update:any={};if(translated.turns){update.telugu_transcript=translated.turns;update.transcript_kind=translated.kind;const summary=pickupSummary(translated.turns);if(summary){update.customer_response_te=summary;update.customer_summary_te=summary}}if(recording.available){update.recording_available=true;update.recording_provider_ref=interactionId;update.recording_content_type=recording.contentType}if(Object.keys(update).length){const {error}=await admin.from("call_logs").update(update).eq("id",logId);if(error)throw error}}catch(e){console.warn("Call enrichment unavailable",e instanceof Error?e.message:"unknown")}}
function analyticsUrl(kind:string,id:string){return `https://apps.sarvam.ai/api/analytics/v1/${encodeURIComponent(Deno.env.get("SARVAM_ORG_ID")!)}/${encodeURIComponent(Deno.env.get("SARVAM_WORKSPACE_ID")!)}/${encodeURIComponent(Deno.env.get("SARVAM_APP_ID")!)}/${kind}/${encodeURIComponent(id)}`}
function safeEqual(a:string,b:string){if(a.length!==b.length)return false;let x=0;for(let i=0;i<a.length;i++)x|=a.charCodeAt(i)^b.charCodeAt(i);return x===0}
function outcomeValue(v:unknown,status:string){return typeof v==="string"&&OUTCOMES.has(v)?v:status==="completed"?"tentative":status}
function duration(v:unknown){const n=Number(v);return Number.isFinite(n)&&n>=0?Math.round(n):null}
function dateTime(v:unknown){if(typeof v!=="string")return null;const d=new Date(v);return Number.isNaN(d.valueOf())?null:d.toISOString()}
function isoDate(v:unknown){if(typeof v!=="string"||!/^\d{4}-\d{2}-\d{2}$/.test(v))return null;const d=new Date(`${v}T12:00:00+05:30`);return Number.isNaN(d.valueOf())?null:v}
function isoTime(v:unknown){return typeof v==="string"&&/^([01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$/.test(v)?v:null}
function period(v:unknown){return typeof v==="string"&&["morning","afternoon","evening","night"].includes(v)?v:null}
function text(v:unknown,max:number){return typeof v==="string"?v.slice(0,max):null}
function telugu(v:unknown){return typeof v==="string"&&/[\u0C00-\u0C7F]/.test(v)?v:null}
function truthy(v:unknown){return v===true||(typeof v==="string"&&v.toLowerCase()==="true")}
function redact(p:any){const copy=structuredClone(p);if(copy?.webhook_config?.url)copy.webhook_config.url="[redacted]";return copy}
