type PageResult<T> = { data: T[] | null; error: { message: string } | null };
type PageQuery<T> = { range(from: number, to: number): PromiseLike<PageResult<T>> };
/** Callers provide a stable unique ordering. Supabase caps each response independently. */
export async function readAll<T>(query: PageQuery<T>): Promise<{ data: T[]; error: null }> {
  const data: T[] = [], size = 500;
  for (let offset = 0; ; offset += size) {
    const page = await query.range(offset, offset + size - 1);
    if (page.error) throw new Error(page.error.message);
    data.push(...(page.data || []));
    if (!page.data || page.data.length < size) return { data, error: null };
  }
}
