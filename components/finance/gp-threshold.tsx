import {currentAccess} from '@/lib/security/access';
import {gpThreshold} from '@/lib/finance/data';
import {ThresholdForm} from './small-forms';
export async function GpThreshold(){const[a,threshold]=await Promise.all([currentAccess(),gpThreshold()]);return <section className="card mb-5 p-5"><h2 className="mb-3 font-semibold">Low GP Warning Threshold %</h2>{a.admin&&a.grants['configuration.masters']?.canEdit?<ThresholdForm threshold={threshold}/>:<p>{threshold}%</p>}</section>;}
