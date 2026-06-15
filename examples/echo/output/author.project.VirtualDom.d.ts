export const attribute: (p0: string, p1: string) => Attribute<MSG>;

export const attributeNS: (p0: string, p1: string, p2: string) => Attribute<MSG>;

export const block2: (p0: (p0: A, p1: B) => Node<MSG>, p1: A, p2: B) => Node<MSG>;

export const block3: (p0: (p0: A, p1: B, p2: C) => Node<MSG>, p1: A, p2: B, p3: C) => Node<MSG>;

export const cssAttribute: (p0: ReadonlyArray<{ readonly declarations: string; readonly selector: string }>) => Attribute<MSG>;

export const keyedNode: (p0: string, p1: ReadonlyArray<Attribute<MSG>>, p2: ReadonlyArray<{ readonly a: string; readonly b: Node<MSG> }>) => Node<MSG>;

export const keyedNodeNS: (p0: string, p1: string, p2: ReadonlyArray<Attribute<MSG>>, p3: ReadonlyArray<{ readonly a: string; readonly b: Node<MSG> }>) => Node<MSG>;

export const lazy: (p0: (p0: A) => Node<MSG>, p1: A) => Node<MSG>;

export const lazy2: (p0: (p0: A, p1: B) => Node<MSG>, p1: A, p2: B) => Node<MSG>;

export const lazy3: (p0: (p0: A, p1: B, p2: C) => Node<MSG>, p1: A, p2: B, p3: C) => Node<MSG>;

export const lazy4: (p0: (p0: A, p1: B, p2: C, p3: D) => Node<MSG>, p1: A, p2: B, p3: C, p4: D) => Node<MSG>;

export const lazy5: (p0: (p0: A, p1: B, p2: C, p3: D, p4: E) => Node<MSG>, p1: A, p2: B, p3: C, p4: D, p5: E) => Node<MSG>;

export const lazy6: (p0: (p0: A, p1: B, p2: C, p3: D, p4: E, p5: F) => Node<MSG>, p1: A, p2: B, p3: C, p4: D, p5: E, p6: F) => Node<MSG>;

export const lazy7: (p0: (p0: A, p1: B, p2: C, p3: D, p4: E, p5: F, p6: G) => Node<MSG>, p1: A, p2: B, p3: C, p4: D, p5: E, p6: F, p7: G) => Node<MSG>;

export const lazy8: (p0: (p0: A, p1: B, p2: C, p3: D, p4: E, p5: F, p6: G, p7: H) => Node<MSG>, p1: A, p2: B, p3: C, p4: D, p5: E, p6: F, p7: G, p8: H) => Node<MSG>;

export const map: (p0: (p0: A) => MSG, p1: Node<A>) => Node<MSG>;

export const mapAttribute: (p0: (p0: A) => B, p1: Attribute<A>) => Attribute<B>;

export const noJavaScriptOrHtmlJson: (p0: Value) => Value;

export const noJavaScriptOrHtmlUri: (p0: string) => string;

export const noJavaScriptUri: (p0: string) => string;

export const noScript: (p0: string) => string;

export const node: (p0: string, p1: ReadonlyArray<Attribute<MSG>>, p2: ReadonlyArray<Node<MSG>>) => Node<MSG>;

export const nodeNS: (p0: string, p1: string, p2: ReadonlyArray<Attribute<MSG>>, p3: ReadonlyArray<Node<MSG>>) => Node<MSG>;

export const on: (p0: string, p1: Handler<MSG>) => Attribute<MSG>;

export const property: (p0: string, p1: Value) => Attribute<MSG>;

export const style: (p0: string, p1: string) => Attribute<MSG>;

export const text: (p0: string) => Node<MSG>;

export const toHandlerInt: (p0: Handler<MSG>) => number;

export type Attribute<MSG> = { readonly $: 'Attribute' };

export type Handler<MSG> = { readonly $: 'Normal'; readonly a: Decoder<MSG> } | { readonly $: 'MayStopPropagation'; readonly a: Decoder<{ readonly a: MSG; readonly b: boolean }> } | { readonly $: 'MayPreventDefault'; readonly a: Decoder<{ readonly a: MSG; readonly b: boolean }> } | { readonly $: 'Custom'; readonly a: Decoder<{ readonly message: MSG; readonly preventDefault: boolean; readonly stopPropagation: boolean }> };

export type Node<MSG> = { readonly $: 'Node' };

