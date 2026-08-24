import { notFound } from "next/navigation";
import { ComingSoon } from "@/components/ui/coming-soon";
import { primaryNavigation } from "@/lib/modules";
export default async function ModulePage({ params }: { params: Promise<{ module: string }> }) { const { module: slug } = await params; const definition = primaryNavigation.find((item) => item.href === `/${slug}` && item.href !== "/dashboard"); if (!definition) notFound(); return <ComingSoon title={definition.title} phase={definition.phase}/>; }
