import{requirePurchaseEdit}from'@/lib/security/access';export default async function Layout({children}:{children:React.ReactNode}){await requirePurchaseEdit('purchase.orders');return children}
