export const KEY = "hanshang-section-times-v1";
const summer = ["08:00","08:55","09:55","10:50","11:45","14:30","15:25","16:20","17:15","18:10","19:30","20:25"];
export function clock(minutes) { return `${String(Math.floor(minutes / 60)).padStart(2,"0")}:${String(minutes % 60).padStart(2,"0")}`; }
export function minutes(value) { return /^(?:[01]\d|2[0-3]):[0-5]\d$/.test(value) ? Number(value.slice(0,2))*60+Number(value.slice(3)) : NaN; }
export function defaults(date) { const winter = date.getMonth()<4 || date.getMonth()>8; return summer.map((start,i)=>{const n=minutes(start)-(winter && i>=5 ? 30 : 0); return [clock(n),clock(n+45)];}); }
export function validate(times) {
  if (!Array.isArray(times) || times.length!==12) return "请设置完整的 12 节课时间";
  let previous=-1;
  for (let i=0;i<12;i++) {
    const t=times[i]; if (!Array.isArray(t)||t.length!==2||t.some(v=>typeof v!=="string" || !Number.isFinite(minutes(v)))) return `第 ${i+1} 节时间格式不正确`;
    const [a,b]=t.map(minutes); if(b<=a) return `第 ${i+1} 节下课时间必须晚于上课时间`;
    if(a<previous) return `第 ${i+1} 节与上一节时间重叠`; previous=b;
  } return "";
}
export function parse(raw) { try { const d=JSON.parse(raw); if(d.version===1 && d.mode==="custom" && !validate(d.times)) return d; } catch {} return {version:1,mode:"automatic"}; }
export function forDate(config,date) { return config.mode==="custom" ? config.times : defaults(date); }
