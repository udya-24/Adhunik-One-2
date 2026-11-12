declare module "sax" {
  type Tag = { name: string; attributes: Record<string, string> };
  type Parser = { onopentag: (tag: Tag) => void; ontext: (value: string) => void; oncdata: (value: string) => void; onclosetag: () => void; write(value: string): Parser; close(): void };
  const sax: { parser(strict: boolean, options: Record<string, boolean>): Parser };
  export default sax;
}
