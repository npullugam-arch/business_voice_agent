type Turn={role?:string;indic_text?:string|null;text?:string|null};

const TELUGU=/[\u0C00-\u0C7F]/;
const HAS_TIME=/\d|[\u0C66-\u0C6F]/;

export function pickupSummary(turns:Turn[]|null|undefined,...preferred:unknown[]):string|null{
  for(const value of preferred){const clean=teluguText(value);if(clean)return clean}
  const customer=(Array.isArray(turns)?turns:[]).filter(turn=>turn?.role==="user").map(turn=>teluguText(turn.indic_text??turn.text)).filter(Boolean) as string[];
  if(!customer.length)return null;
  return [...customer].reverse().find(value=>HAS_TIME.test(value))??customer.at(-1)??null;
}

function teluguText(value:unknown){
  if(typeof value!=="string"||!TELUGU.test(value))return null;
  const clean=value.replace(/\s+/g," ").trim();
  return clean?clean.slice(0,500):null;
}
