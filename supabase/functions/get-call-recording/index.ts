import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {createClient} from "jsr:@supabase/supabase-js@2";
import {corsHeaders,json} from "../_shared/http.ts";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
Deno.serve(async req=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:corsHeaders});
  if(req.method!=="GET")return json({ok:false},405);
  const auth=req.headers.get("Authorization"),id=new URL(req.url).searchParams.get("call_log_id")||"";
  if(!auth?.startsWith("Bearer ")||!UUID.test(id))return json({ok:false},401);
  const userDb=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_ANON_KEY")!,{global:{headers:{Authorization:auth}}});
  const {data:log,error}=await userDb.from("call_logs").select("recording_available,recording_provider_ref").eq("id",id).maybeSingle();
  if(error||!log)return json({ok:false,message:"Recording not found"},404);
  if(!log.recording_available||!log.recording_provider_ref)return json({ok:false,message:"Recording is not available for this call"},404);
  const endpoint=`https://apps.sarvam.ai/api/analytics/v1/${encodeURIComponent(Deno.env.get("SARVAM_ORG_ID")!)}/${encodeURIComponent(Deno.env.get("SARVAM_WORKSPACE_ID")!)}/${encodeURIComponent(Deno.env.get("SARVAM_APP_ID")!)}/recordings/${encodeURIComponent(log.recording_provider_ref)}`;
  try{
    const provider=await fetch(endpoint,{headers:{"X-API-Key":Deno.env.get("SARVAM_API_KEY")!}});
    if(!provider.ok)return json({ok:false,message:"Recording is no longer available"},provider.status===404?404:502);
    const contentType=provider.headers.get("Content-Type")||"application/octet-stream";
    if(contentType.includes("application/json")){
      const body=await provider.json(),remote=body.recording_url||body.audio_url||body.url;
      if(typeof remote!=="string"||!/^https:\/\//.test(remote))return json({ok:false,message:"Sarvam did not return playable audio"},502);
      const audio=await fetch(remote);if(!audio.ok||!audio.body)return json({ok:false,message:"Recording could not be downloaded"},502);
      return stream(audio);
    }
    if(!provider.body)return json({ok:false,message:"Recording is empty"},502);
    return stream(provider);
  }catch{return json({ok:false,message:"Recording could not be loaded"},502)}
});
function stream(source:Response){const headers={...corsHeaders,"Content-Type":source.headers.get("Content-Type")||"audio/mpeg","Cache-Control":"private, no-store","Content-Disposition":"inline"};return new Response(source.body,{status:200,headers})}
