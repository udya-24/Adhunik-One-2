type Version = { id: string; root_po_id: string; revision_number: number; status: string };
export function latestReceiptVersions<T extends Version>(versions: T[]): T[] {
  const latest = new Map<string, T>();
  for (const version of versions) {
    if (!['CONFIRMED', 'PARTIALLY_RECEIVED', 'FULLY_RECEIVED', 'CLOSED'].includes(version.status)) continue;
    const previous = latest.get(version.root_po_id);
    if (!previous || version.revision_number > previous.revision_number) latest.set(version.root_po_id, version);
  }
  return [...latest.values()];
}
export function receiptQueueBalance(items: { quantity: number; received: number }[]) {
  const ordered = items.reduce((sum, item) => sum + Number(item.quantity), 0);
  const received = items.reduce((sum, item) => sum + Number(item.received), 0);
  const pending = items.reduce((sum, item) => sum + Math.max(0, Number(item.quantity) - Number(item.received)), 0);
  return { ordered, received, pending, status: pending === 0 ? 'Completed' : received > 0 ? 'Partially Received' : 'Pending Receipt' };
}
