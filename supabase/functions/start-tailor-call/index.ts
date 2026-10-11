import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {createClient} from "jsr:@supabase/supabase-js@2";
import {corsHeaders,json,publicMessage} from "../_shared/http.ts";

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
Deno.serve(async(req)=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:corsHeaders});
  if(req.method!=="POST")return json({ok:false},405);
  const auth=req.headers.get("Authorization");if(!auth?.startsWith("Bearer "))return json({ok:false,message:"Your session has expired. Refresh the page."},401);
  const url=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!,service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const userDb=createClient(url,anon,{global:{headers:{Authorization:auth}}});const admin=createClient(url,service);
  try{
    const body=await req.json();if(!UUID.test(body?.order_id||""))return json({ok:false,message:"The order details are invalid."},400);
    const {data:userData,error:userError}=await userDb.auth.getUser();if(userError||!userData.user)return json({ok:false,message:"Your session has expired. Refresh the page."},401);
    const {data:claim,error:claimError}=await userDb.rpc("claim_call_job",{p_order_id:body.order_id});
    if(claimError){const duplicate=claimError.code==="23505";return json({ok:false,message:publicMessage(duplicate?"duplicate":"not_eligible")},409)}
    const c=claim?.[0];if(!c)return json({ok:false,message:publicMessage("not_eligible")},409);
    const mode=(Deno.env.get("CALL_MODE")||"live").toLowerCase();
    if(mode==="mock"){
      const attempt=`mock-${crypto.randomUUID()}`;
      await admin.from("call_jobs").update({status:"completed",provider_request_id:attempt,completed_at:new Date().toISOString()}).eq("id",c.job_id);
      await admin.from("call_logs").insert({owner_id:c.owner_id,order_id:body.order_id,customer_id:c.customer_id,provider:"mock",provider_attempt_id:attempt,status:"completed",call_outcome:"tentative",completed_at:new Date().toISOString(),customer_response:"Test mode only — no real phone call was placed"});
      await admin.from("orders").update({call_status:"completed"}).eq("id",body.order_id).neq("status","collected");
      return json({ok:true,test_mode:true,status:"completed",message:"Test mode: no real phone call was placed."});
    }
    const required=["SARVAM_API_KEY","SARVAM_ORG_ID","SARVAM_WORKSPACE_ID","SARVAM_APP_ID","SARVAM_APP_VERSION","SARVAM_CONNECTION_ID","SARVAM_AGENT_PHONE_NUMBER","SARVAM_WEBHOOK_URL","SARVAM_WEBHOOK_SECRET"];
    if(required.some(k=>!Deno.env.get(k))){await fail(admin,c.job_id,body.order_id,"configuration_missing");return json({ok:false,message:publicMessage("not_configured")},503)}
    const appVersion=Number(Deno.env.get("SARVAM_APP_VERSION"));
    let webhook:URL;
    try{webhook=new URL(Deno.env.get("SARVAM_WEBHOOK_URL")!)}catch{await fail(admin,c.job_id,body.order_id,"invalid_webhook_url");return json({ok:false,message:publicMessage("invalid_config")},503)}
    if(!Number.isInteger(appVersion)||appVersion<1||!/^\+[1-9]\d{7,14}$/.test(Deno.env.get("SARVAM_AGENT_PHONE_NUMBER")!)){await fail(admin,c.job_id,body.order_id,"invalid_app_version_or_agent_phone");return json({ok:false,message:publicMessage("invalid_config")},503)}
    webhook.searchParams.set("token",Deno.env.get("SARVAM_WEBHOOK_SECRET")!);
    const payload={app_config:{app_id:Deno.env.get("SARVAM_APP_ID"),app_version:appVersion,connection_config:{connection_id:Deno.env.get("SARVAM_CONNECTION_ID"),agent_phone_number:Deno.env.get("SARVAM_AGENT_PHONE_NUMBER")},agent_variables:{customer_name:c.customer_name,shop_name:c.shop_name,garment_name:c.garment_type,order_id:body.order_id,timezone:"Asia/Kolkata"},app_overrides:{initial_language_name:"Telugu"}},user_config:{user_phone_number:c.phone_e164},webhook_config:{url:webhook.toString(),metadata:{call_job_id:c.job_id,order_id:body.order_id,customer_id:c.customer_id}}};
    const endpoint=`https://apps.sarvam.ai/api/outbounds/v1/orgs/${encodeURIComponent(Deno.env.get("SARVAM_ORG_ID")!)}/workspaces/${encodeURIComponent(Deno.env.get("SARVAM_WORKSPACE_ID")!)}/outbounds`;
    const res=await fetch(endpoint,{method:"POST",headers:{"X-API-Key":Deno.env.get("SARVAM_API_KEY")!,"Content-Type":"application/json"},body:JSON.stringify(payload)});
    const provider=await res.json().catch(()=>({}));if(!res.ok||typeof provider.attempt_id!=="string"){const detail=providerDetail(provider);console.error("Sarvam outbound request failed",{status:res.status,detail});await fail(admin,c.job_id,body.order_id,`sarvam_${res.status}${detail?`: ${detail}`:""}`);const explainable=res.status===404||res.status===422;const message=`${publicMessage(`sarvam_${res.status}`)}${explainable&&detail?` Sarvam says: ${detail}`:""}`;return json({ok:false,message},502)}
    await admin.from("call_jobs").update({status:"submitted",provider_request_id:provider.attempt_id}).eq("id",c.job_id);
    await admin.from("call_logs").insert({owner_id:c.owner_id,order_id:body.order_id,customer_id:c.customer_id,provider:"sarvam",provider_attempt_id:provider.attempt_id,status:"calling"});
    await admin.from("orders").update({call_status:"calling"}).eq("id",body.order_id).neq("status","collected");
    return json({ok:true,status:"calling",message:"The call has been submitted to Sarvam."});
  }catch(e){console.error("start-tailor-call",e instanceof Error?e.name:"unknown");return json({ok:false,message:publicMessage("provider_failed")},500)}
});
async function fail(admin:any,job:string,order:string,reason:string){await admin.from("call_jobs").update({status:"failed",error_message:reason,completed_at:new Date().toISOString()}).eq("id",job);await admin.from("orders").update({call_status:"failed"}).eq("id",order).neq("status","collected")}
function providerDetail(value:unknown){if(!value||typeof value!=="object")return "";const body=value as Record<string,unknown>;const candidate=body.detail??body.message??body.error;const text=typeof candidate==="string"?candidate:JSON.stringify(candidate??"");return text.replace(/[\r\n]+/g," ").slice(0,500)}
