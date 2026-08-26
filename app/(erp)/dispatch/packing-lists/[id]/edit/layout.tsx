import {requireEdit} from "@/lib/security/access";

export default async function PackingListEditLayout({children}:{children:React.ReactNode}){
  await requireEdit("dispatch.packing_lists");
  return children;
}
