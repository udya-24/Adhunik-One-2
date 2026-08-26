import {requireView} from "@/lib/security/access";

export default async function PackingListLayout({children}:{children:React.ReactNode}){
  await requireView("dispatch.packing_lists");
  return children;
}
