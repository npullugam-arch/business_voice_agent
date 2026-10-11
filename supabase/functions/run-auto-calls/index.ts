import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {createClient} from "jsr:@supabase/supabase-js@2";
import {json} from "../_shared/http.ts";

Deno.serve(async req=>{
  if(req.method!=="POST")return json({ok:false},405);
  const admin=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  try{
    const supplied=req.headers.get("X-Cron-Secret")||"";
    const {data:stored,error:secretError}=await admin.from("internal_automation_secrets").select("secret").eq("name","auto_call_cron").maybeSingle();
    if(secretError||!stored?.secret||!safeEqual(stored.secret,supplied))return json({ok:false},401);
    const {data:claims,error:claimError}=await admin.rpc("claim_automatic_call_jobs",{p_limit:3});
    if(claimError)throw claimError;
    const results=[];
    for(const claim of claims||[]){results.push(await submit(admin,claim));await new Promise(resolve=>setTimeout(resolve,800))}
    return json({ok:true,claimed:claims?.length||0,submitted:results.filter(item=>item.ok).length,results});
  }catch(error){console.error("run-auto-calls",error instanceof Error?error.message:"unknown");return json({ok:false,message:"Automatic call dispatch failed"},500)}
});

async function submit(admin:any,c:any){
  const {data:job}=await admin.from("call_jobs").select("status").eq("id",c.job_id).maybeSingle();
  const {data:order}=await admin.from("orders").select("status,call_enabled").eq("id",c.order_id).maybeSingle();
  if(job?.status!=="claimed"||!order||order.status==="collected"||!order.call_enabled){await admin.from("call_jobs").update({status:"cancelled",completed_at:new Date().toISOString()}).eq("id",c.job_id);return{job_id:c.job_id,ok:false,cancelled:true}}
  const mode=(Deno.env.get("CALL_MODE")||"live").toLowerCase();
  if(mode==="mock"){
    const attempt=`mock-auto-${crypto.randomUUID()}`;
    await admin.from("call_jobs").update({status:"completed",provider_request_id:attempt,completed_at:new Date().toISOString()}).eq("id",c.job_id);
    await admin.from("call_logs").insert({owner_id:c.owner_id,order_id:c.order_id,customer_id:c.customer_id,provider:"mock",provider_attempt_id:attempt,status:"completed",call_outcome:"tentative",completed_at:new Date().toISOString(),automatic:true,campaign_id:c.campaign_id,attempt_number:c.attempt_number,customer_response:"Automatic test mode; no phone call was placed"});
    await admin.from("orders").update({call_status:"completed",next_call_at:null}).eq("id",c.order_id).neq("status","collected");
    return{job_id:c.job_id,ok:true,test_mode:true};
  }
  const required=["SARVAM_API_KEY","SARVAM_ORG_ID","SARVAM_WORKSPACE_ID","SARVAM_APP_ID","SARVAM_APP_VERSION","SARVAM_CONNECTION_ID","SARVAM_AGENT_PHONE_NUMBER","SARVAM_WEBHOOK_URL","SARVAM_WEBHOOK_SECRET"];
  if(required.some(key=>!Deno.env.get(key)))return fail(admin,c,"configuration_missing");
  const appVersion=Number(Deno.env.get("SARVAM_APP_VERSION"));let webhook:URL;
  try{webhook=new URL(Deno.env.get("SARVAM_WEBHOOK_URL")!)}catch{return fail(admin,c,"invalid_webhook_url")}
  webhook.searchParams.set("token",Deno.env.get("SARVAM_WEBHOOK_SECRET")!);
  const payload={app_config:{app_id:Deno.env.get("SARVAM_APP_ID"),app_version:appVersion,connection_config:{connection_id:Deno.env.get("SARVAM_CONNECTION_ID"),agent_phone_number:Deno.env.get("SARVAM_AGENT_PHONE_NUMBER")},agent_variables:{customer_name:c.customer_name,shop_name:c.shop_name,garment_name:c.garment_type,order_id:c.order_id,timezone:"Asia/Kolkata",automatic_call:"true",attempt_number:String(c.attempt_number)},app_overrides:{initial_language_name:"Telugu"}},user_config:{user_phone_number:c.phone_e164},webhook_config:{url:webhook.toString(),metadata:{call_job_id:c.job_id,order_id:c.order_id,customer_id:c.customer_id,campaign_id:c.campaign_id,automatic:true,attempt_number:c.attempt_number}}};
  const endpoint=`https://apps.sarvam.ai/api/outbounds/v1/orgs/${encodeURIComponent(Deno.env.get("SARVAM_ORG_ID")!)}/workspaces/${encodeURIComponent(Deno.env.get("SARVAM_WORKSPACE_ID")!)}/outbounds`;
  try{
    const response=await fetch(endpoint,{method:"POST",headers:{"X-API-Key":Deno.env.get("SARVAM_API_KEY")!,"Content-Type":"application/json"},body:JSON.stringify(payload)});
    const provider=await response.json().catch(()=>({}));
    if(!response.ok||typeof provider.attempt_id!=="string")return fail(admin,c,`sarvam_${response.status}`);
    await admin.from("call_jobs").update({status:"submitted",provider_request_id:provider.attempt_id}).eq("id",c.job_id).eq("status","claimed");
    await admin.from("call_logs").insert({owner_id:c.owner_id,order_id:c.order_id,customer_id:c.customer_id,provider:"sarvam",provider_attempt_id:provider.attempt_id,status:"calling",automatic:true,campaign_id:c.campaign_id,attempt_number:c.attempt_number});
    await admin.from("orders").update({call_status:"calling"}).eq("id",c.order_id).neq("status","collected");
    return{job_id:c.job_id,ok:true,attempt_number:c.attempt_number};
  }catch{return fail(admin,c,"provider_request_failed")}
}

async function fail(admin:any,c:any,reason:string){
  const attempt=`auto-failed-${crypto.randomUUID()}`;
  await admin.from("call_jobs").update({status:"failed",error_message:reason,completed_at:new Date().toISOString(),provider_request_id:attempt}).eq("id",c.job_id);
  await admin.from("call_logs").insert({owner_id:c.owner_id,order_id:c.order_id,customer_id:c.customer_id,provider:"sarvam",provider_attempt_id:attempt,status:"failed",call_outcome:"failed",completed_at:new Date().toISOString(),failure_reason:reason,automatic:true,campaign_id:c.campaign_id,attempt_number:c.attempt_number});
  await admin.from("orders").update({call_status:"failed",next_call_at:null}).eq("id",c.order_id).neq("status","collected");
  return{job_id:c.job_id,ok:false,reason};
}
function safeEqual(a:string,b:string){if(a.length!==b.length)return false;let value=0;for(let i=0;i<a.length;i++)value|=a.charCodeAt(i)^b.charCodeAt(i);return value===0}
