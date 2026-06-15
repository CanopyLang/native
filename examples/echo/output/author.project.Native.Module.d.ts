export const call: (p0: string, p1: string, p2: Value, p3: Decoder<A>) => Task<Error, A>;

export const callStreaming: (p0: string, p1: string, p2: Value, p3: (p0: Value) => Task<void, void>) => Task<Error, ProcessId>;

export const cancel: (p0: string) => Task<X, void>;

export type Error = { readonly $: 'ModuleNotFound'; readonly a: string } | { readonly $: 'Rejected'; readonly a: string } | { readonly $: 'Decode'; readonly a: string } | { readonly $: 'Cancelled' };

