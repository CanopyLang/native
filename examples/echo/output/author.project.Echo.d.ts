export const send: (p0: string, p1: (p0: { readonly $: 'Ok'; readonly a: string } | { readonly $: 'Err'; readonly a: Error }) => MSG) => Cmd<MSG>;

