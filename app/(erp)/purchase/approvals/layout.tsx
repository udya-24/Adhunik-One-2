import{requirePurchaseView}from'@/lib/security/access';export default async function Layout({children}:{children:React.ReactNode}){await requirePurchaseView('purchase.orders');return children}
