/** Decimal strings stay exact through input and display; multiplication happens in PostgreSQL. */
export function priceInput(value: string):string|null {
  const v=value.trim();if(!v)return null;
  if(!/^\d+(\.\d{1,4})?$/.test(v))throw new Error("Prices must be non-negative with at most four decimal places.");
  const [whole,fraction=""]=v.split(".");if(BigInt(whole)>=BigInt(100000000000))throw new Error("Price exceeds the supported range.");
  return BigInt(whole).toString()+"."+fraction.padEnd(4,"0");
}
export function inr(value:string|null|undefined):string {
  if(value==null)return "Unknown";
  if(!/^-?\d+(\.\d+)?$/.test(value))throw new Error("Expected an exact decimal value.");
  const negative=value.startsWith("-"),[whole,fraction=""]=(negative?value.slice(1):value).split(".");
  const cents=BigInt(whole)*BigInt(100)+BigInt(fraction.padEnd(2,"0").slice(0,2))+(Number(fraction[2]??"0")>=5?BigInt(1):BigInt(0));
  return (negative&&cents!==BigInt(0)?"−":"")+"₹"+new Intl.NumberFormat("en-IN").format(cents/BigInt(100))+"."+(cents%BigInt(100)).toString().padStart(2,"0");
}
