import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {corsHeaders,json} from "../_shared/http.ts";

const encoder=new TextEncoder();
const bytesToBase64=(bytes:Uint8Array)=>btoa(String.fromCharCode(...bytes)).replaceAll("+","-").replaceAll("/","_").replaceAll("=","");
const base64ToBytes=(value:string)=>Uint8Array.from(atob(value.replaceAll("-","+").replaceAll("_","/")+"===".slice((value.length+3)%4)),c=>c.charCodeAt(0));
function safeEqual(a:string,b:string){const aa=encoder.encode(a),bb=encoder.encode(b);if(aa.length!==bb.length)return false;let result=0;for(let i=0;i<aa.length;i++)result|=aa[i]^bb[i];return result===0}
async function signature(payload:string){const secret=Deno.env.get("ADMIN_SESSION_SECRET")||"",key=await crypto.subtle.importKey("raw",encoder.encode(secret),{name:"HMAC",hash:"SHA-256"},false,["sign"]);return bytesToBase64(new Uint8Array(await crypto.subtle.sign("HMAC",key,encoder.encode(payload))))}
async function issueToken(){const payload=bytesToBase64(encoder.encode(JSON.stringify({role:"admin",exp:Date.now()+12*60*60*1000})));return`${payload}.${await signature(payload)}`}
async function verifyToken(token:unknown){if(typeof token!=="string"||!token.includes("."))return false;const [payload,sig]=token.split(".");if(!safeEqual(sig,await signature(payload)))return false;try{const data=JSON.parse(new TextDecoder().decode(base64ToBytes(payload)));return data.role==="admin"&&Number(data.exp)>Date.now()}catch{return false}}

Deno.serve(async req=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:corsHeaders});
  if(req.method!=="POST")return json({ok:false,message:"Method not allowed"},405);
  try{
    const body=await req.json();
    if(body.action==="verify")return await verifyToken(body.token)?json({ok:true}):json({ok:false,message:"Admin session expired"},401);
    const username=Deno.env.get("ADMIN_USERNAME")||"admin",password=Deno.env.get("ADMIN_PASSWORD")||"";
    if(!password||!safeEqual(String(body.username||""),username)||!safeEqual(String(body.password||""),password)){
      await new Promise(resolve=>setTimeout(resolve,500));return json({ok:false,message:"Invalid username or password"},401);
    }
    return json({ok:true,token:await issueToken()});
  }catch{return json({ok:false,message:"Admin sign-in failed"},400)}
});
