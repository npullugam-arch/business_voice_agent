import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {createClient} from "jsr:@supabase/supabase-js@2";
import {corsHeaders,json} from "../_shared/http.ts";
import {pickupSummary} from "../_shared/pickup-summary.ts";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

Deno.serve(async req=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:corsHeaders});
  if(req.method!=="POST")return json({ok:false},405);
  const auth=req.headers.get("Authorization");
  if(!auth?.startsWith("Bearer "))return json({ok:false},401);
  try{
    const body=await req.json(),id=body?.call_log_id||"";
    if(!UUID.test(id))return json({ok:false},400);
    const url=Deno.env.get("SUPABASE_URL")!;
    const userDb=createClient(url,Deno.env.get("SUPABASE_ANON_KEY")!,{global:{headers:{Authorization:auth}}});
    const admin=createClient(url,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const {data:log,error}=await userDb.from("call_logs").select("id,provider_interaction_id,provider_transcript,telugu_transcript,customer_response_te,customer_summary_te,recording_available").eq("id",id).maybeSingle();
    if(error||!log)return json({ok:false,message:"Call not found"},404);
    let transcript=Array.isArray(log.provider_transcript)&&log.provider_transcript.length?log.provider_transcript:null;
    let recordingAvailable=log.recording_available===true;
    let recordingContentType:string|null=null;

    if(!transcript&&log.provider_interaction_id){
      try{
        const provider=await fetch(analyticsUrl("transcripts",log.provider_interaction_id),{headers:{"X-API-Key":Deno.env.get("SARVAM_API_KEY")!}});
        if(provider.ok){
          const raw=await provider.text();let payload:any=raw;
          try{payload=JSON.parse(raw)}catch{}
          if(payload&&typeof payload==="object"){
            const remote=payload.transcript_url||payload.url;
            if(typeof remote==="string"&&/^https:\/\//.test(remote)){
              const downloaded=await fetch(remote);
              if(downloaded.ok){const value=await downloaded.text();try{payload=JSON.parse(value)}catch{payload=value}}
            }
          }
          transcript=extractTranscript(payload);
          if(!transcript.length)transcript=null;
        }
      }catch(e){console.warn("Transcript is not ready",e instanceof Error?e.message:"unknown")}
    }

    if(!recordingAvailable&&log.provider_interaction_id){
      try{
        const recording=await fetch(analyticsUrl("recordings",log.provider_interaction_id),{headers:{"X-API-Key":Deno.env.get("SARVAM_API_KEY")!}});
        if(recording.ok){recordingAvailable=true;recordingContentType=recording.headers.get("Content-Type");await recording.body?.cancel()}
      }catch(e){console.warn("Recording is not ready",e instanceof Error?e.message:"unknown")}
    }

    const update:any={};
    if(transcript&&(!Array.isArray(log.provider_transcript)||!log.provider_transcript.length)){
      const originalTelugu=transcript.every((turn:any)=>hasTelugu(turn.indic_text))?transcript.map((turn:any)=>({role:turn.role,text:turn.indic_text})):null;
      update.transcript=transcript;update.provider_transcript=transcript;update.telugu_transcript=originalTelugu;
      update.transcript_kind=originalTelugu?"original_telugu":"provider_english";
    }
    const summary=pickupSummary(update.telugu_transcript||log.telugu_transcript||transcript,log.customer_summary_te,log.customer_response_te);
    if(summary&&(!log.customer_summary_te||!log.customer_response_te)){update.customer_summary_te=summary;update.customer_response_te=summary}
    if(recordingAvailable&&!log.recording_available&&log.provider_interaction_id){
      update.recording_available=true;update.recording_provider_ref=log.provider_interaction_id;update.recording_content_type=recordingContentType;
    }
    if(Object.keys(update).length){const {error:updateError}=await admin.from("call_logs").update(update).eq("id",log.id);if(updateError)throw updateError}
    return json({ok:true,transcript_available:Boolean(transcript),recording_available:recordingAvailable,updated:Object.keys(update).length>0});
  }catch(e){console.error("get-call-transcript",e instanceof Error?e.message:"unknown");return json({ok:false,message:"Call assets could not be retrieved"},500)}
});

function analyticsUrl(kind:string,id:string){return `https://apps.sarvam.ai/api/analytics/v1/${encodeURIComponent(Deno.env.get("SARVAM_ORG_ID")!)}/${encodeURIComponent(Deno.env.get("SARVAM_WORKSPACE_ID")!)}/${encodeURIComponent(Deno.env.get("SARVAM_APP_ID")!)}/${kind}/${encodeURIComponent(id)}`}
function extractTranscript(payload:any){const array=findTurns(payload);if(array)return array.map(normalizeTurn).filter(Boolean) as Array<{role:string,en_text:string|null,indic_text:string|null}>;if(typeof payload==="string")return payload.split(/\r?\n/).map(line=>{const match=line.match(/^\s*(agent|assistant|bot|customer|user)\s*:\s*(.+)$/i);if(!match)return null;return{role:/customer|user/i.test(match[1])?"user":"agent",en_text:match[2].trim(),indic_text:hasTelugu(match[2])?match[2].trim():null}}).filter(Boolean) as Array<{role:string,en_text:string|null,indic_text:string|null}>;return[]}
function findTurns(value:any,depth=0):any[]|null{if(depth>6||value==null)return null;if(Array.isArray(value)){if(value.some(item=>item&&typeof item==="object"&&roleOf(item)&&textOf(item)))return value;for(const item of value){const found=findTurns(item,depth+1);if(found)return found}return null}if(typeof value==="object"){for(const key of ["interaction_transcript","transcript","turns","messages","conversation","items","data","result"]){if(key in value){const found=findTurns(value[key],depth+1);if(found)return found}}for(const child of Object.values(value)){const found=findTurns(child,depth+1);if(found)return found}}return null}
function normalizeTurn(turn:any){const role=roleOf(turn),text=textOf(turn);if(!role||!text)return null;const indic=stringValue(turn.indic_text||turn.indicText||turn.original_text||turn.originalText),english=stringValue(turn.en_text||turn.enText||turn.english_text||turn.text||turn.content||turn.transcript);return{role,en_text:english||(!hasTelugu(text)?text:null),indic_text:indic||(hasTelugu(text)?text:null)}}
function roleOf(turn:any){const value=String(turn?.role||turn?.speaker||turn?.participant_type||turn?.participant||"").toLowerCase();if(["agent","assistant","bot","ai"].includes(value))return"agent";if(["user","customer","human","caller"].includes(value))return"user";return null}
function textOf(turn:any){return stringValue(turn?.indic_text||turn?.indicText||turn?.en_text||turn?.enText||turn?.text||turn?.content||turn?.transcript||turn?.message)}
function stringValue(value:any){if(typeof value==="string")return value.trim().slice(0,4000)||null;if(value&&typeof value.text==="string")return value.text.trim().slice(0,4000)||null;return null}
function hasTelugu(value:any){return typeof value==="string"&&/[\u0C00-\u0C7F]/.test(value)}
