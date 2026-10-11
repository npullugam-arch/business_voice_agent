import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {createClient} from "jsr:@supabase/supabase-js@2";
import {corsHeaders,json} from "../_shared/http.ts";
import {pickupSummary} from "../_shared/pickup-summary.ts";

Deno.serve(async req=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:corsHeaders});
  if(req.method!=="POST")return json({ok:false},405);
  const auth=req.headers.get("Authorization");if(!auth?.startsWith("Bearer "))return json({ok:false},401);
  const url=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!,service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const userDb=createClient(url,anon,{global:{headers:{Authorization:auth}}}),admin=createClient(url,service);
  try{
    const {data:{user},error:userError}=await userDb.auth.getUser();if(userError||!user)return json({ok:false},401);
    const {data:pending,error}=await userDb.from("call_logs").select("id,provider_attempt_id,created_at").eq("provider","sarvam").in("status",["queued","calling","connected"]).order("created_at",{ascending:true}).limit(100);
    if(error)throw error;if(!pending?.length)return json({ok:true,pending:0,provider_attempts:0,matched:0,updated:0});
    const start=new Date(new Date(pending[0].created_at).valueOf()-3600000).toISOString(),end=new Date(Date.now()+300000).toISOString();
    const attemptUrl=new URL(`${analyticsBase()}/attempts`);attemptUrl.searchParams.set("start_datetime",start);attemptUrl.searchParams.set("end_datetime",end);attemptUrl.searchParams.set("limit","1000");
    const response=await fetch(attemptUrl,{headers:{"X-API-Key":Deno.env.get("SARVAM_API_KEY")!}});if(!response.ok){const detail=await response.text();throw new Error(`attempts_${response.status}: ${detail.slice(0,300)}`)}
    const body=await response.json(),items=Array.isArray(body.items)?body.items:[],byId=new Map(items.map((item:any)=>[item.attempt_id,item]));let updated=0;
    const enrichment:Array<Promise<void>>=[];
    for(const log of pending){const attempt:any=byId.get(log.provider_attempt_id);if(!attempt)continue;const status=terminal(attempt);if(!status)continue;const interactionId=str(attempt.interaction_id,500),vars=attempt.agent_variables&&typeof attempt.agent_variables==="object"?attempt.agent_variables:{},outcome=validOutcome(vars.call_outcome)?vars.call_outcome:status==="completed"?"tentative":status;
      const shortReply=pickupSummary(null,vars.customer_summary_te,vars.customer_response);
      const result={status,interaction_id:interactionId,call_outcome:outcome,started_at:dateTime(attempt.start_datetime),completed_at:dateTime(attempt.end_datetime),executed_at:dateTime(attempt.start_datetime),duration_seconds:duration(attempt.duration_in_seconds),transcript_kind:"unavailable",customer_response:str(vars.customer_response,2000),customer_response_te:shortReply,customer_summary_te:shortReply,pickup_date:isoDate(vars.pickup_date),pickup_time:isoTime(vars.pickup_time),pickup_period:period(vars.pickup_time_period),follow_up_required:truthy(vars.follow_up_required),callback_requested:truthy(vars.callback_requested),callback_date:isoDate(vars.callback_date),do_not_call:truthy(vars.do_not_call),failure_reason:str(attempt.failure_reason,500),recording_available:typeof attempt.audio_url==="string"&&attempt.audio_url.length>0,recording_provider_ref:typeof attempt.audio_url==="string"&&attempt.audio_url?interactionId:null,raw_payload:{reconciled_from:"sarvam_analytics",attempt_id:attempt.attempt_id}};
      const {data:applied,error:applyError}=await admin.rpc("apply_sarvam_call_result",{p_attempt_id:log.provider_attempt_id,p_result:result});if(applyError)throw applyError;if(applied){updated++;if(interactionId)enrichment.push(enrichTranscript(admin,log.id,interactionId))}
    }
    if(enrichment.length)EdgeRuntime.waitUntil(Promise.allSettled(enrichment));
    return json({ok:true,pending:pending.length,provider_attempts:items.length,matched:pending.filter(log=>byId.has(log.provider_attempt_id)).length,updated});
  }catch(e){const detail=e instanceof Error?e.message:typeof e==="object"&&e?JSON.stringify(e):"Call results could not be synchronized";console.error("sync-call-results",detail);return json({ok:false,message:"Call results could not be synchronized"},502)}
});

function analyticsBase(){return `https://apps.sarvam.ai/api/analytics/v1/${encodeURIComponent(Deno.env.get("SARVAM_ORG_ID")!)}/${encodeURIComponent(Deno.env.get("SARVAM_WORKSPACE_ID")!)}/${encodeURIComponent(Deno.env.get("SARVAM_APP_ID")!)}`}
async function fetchTranscript(id:string){try{const res=await fetch(`${analyticsBase()}/transcripts/${encodeURIComponent(id)}`,{headers:{"X-API-Key":Deno.env.get("SARVAM_API_KEY")!}});if(!res.ok)return null;const body=await res.json();const value=body.interaction_transcript||body.transcript||body.items;if(!Array.isArray(value))return null;const turns=value.map((turn:any)=>({role:turn?.role==="agent"?"agent":turn?.role==="user"?"user":null,en_text:str(turn?.en_text,4000),indic_text:str(turn?.indic_text,4000)})).filter((turn:any)=>turn.role&&(turn.en_text||turn.indic_text));return turns.length?turns:null}catch{return null}}
async function enrichTranscript(admin:any,logId:string,interactionId:string){const transcript=await fetchTranscript(interactionId);if(!transcript)return;const originalTelugu=transcript.every((turn:any)=>telugu(turn.indic_text))?transcript.map((turn:any)=>({role:turn.role,text:turn.indic_text})):null,summary=pickupSummary(originalTelugu||transcript);const update:any={transcript,provider_transcript:transcript,telugu_transcript:originalTelugu,transcript_kind:originalTelugu?"original_telugu":"provider_english"};if(summary){update.customer_response_te=summary;update.customer_summary_te=summary}const {error}=await admin.from("call_logs").update(update).eq("id",logId);if(error)throw error}
function terminal(a:any){if(!a.end_datetime)return null;const value=a.connectivity_status;if(value==="connected")return "completed";if(value==="no_answer"||value==="busy")return value;if(value==="failed")return "failed";return null}
function validOutcome(v:unknown){return typeof v==="string"&&["confirmed","tentative","no_answer","busy","rejected","wrong_number","callback_requested","already_collected_reported","do_not_call","failed"].includes(v)}
function duration(v:unknown){const n=Number(v);return Number.isFinite(n)&&n>=0?Math.round(n):null}
function dateTime(v:unknown){if(typeof v!=="string")return null;const d=new Date(v);return Number.isNaN(d.valueOf())?null:d.toISOString()}
function isoDate(v:unknown){return typeof v==="string"&&/^\d{4}-\d{2}-\d{2}$/.test(v)?v:null}
function isoTime(v:unknown){return typeof v==="string"&&/^([01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$/.test(v)?v:null}
function period(v:unknown){return typeof v==="string"&&["morning","afternoon","evening","night"].includes(v)?v:null}
function str(v:unknown,max:number){return typeof v==="string"?v.slice(0,max):null}
function telugu(v:unknown){return typeof v==="string"&&/[\u0C00-\u0C7F]/.test(v)?v:null}
function truthy(v:unknown){return v===true||(typeof v==="string"&&v.toLowerCase()==="true")}
