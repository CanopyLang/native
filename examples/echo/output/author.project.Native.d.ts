export const button: (p0: ReadonlyArray<Attribute<MSG>>, p1: string) => Node<MSG>;

export const column: (p0: ReadonlyArray<Attribute<MSG>>, p1: ReadonlyArray<Node<MSG>>) => Node<MSG>;

export const element: (p0: { readonly init: (p0: FLAGS) => { readonly a: MODEL; readonly b: Cmd<MSG> }; readonly subscriptions: (p0: MODEL) => Sub<MSG>; readonly update: (p0: MSG, p1: MODEL) => { readonly a: MODEL; readonly b: Cmd<MSG> }; readonly view: (p0: MODEL) => Node<MSG> }) => Program<FLAGS, MODEL, MSG>;

export const image: (p0: ReadonlyArray<Attribute<MSG>>) => Node<MSG>;

export const map: (p0: (p0: A) => MSG, p1: Node<A>) => Node<MSG>;

export const none: Node<MSG>;

export const pressable: (p0: ReadonlyArray<Attribute<MSG>>, p1: ReadonlyArray<Node<MSG>>) => Node<MSG>;

export const rawText: (p0: string) => Node<MSG>;

export const row: (p0: ReadonlyArray<Attribute<MSG>>, p1: ReadonlyArray<Node<MSG>>) => Node<MSG>;

export const scroll: (p0: ReadonlyArray<Attribute<MSG>>, p1: ReadonlyArray<Node<MSG>>) => Node<MSG>;

export const text: (p0: ReadonlyArray<Attribute<MSG>>, p1: string) => Node<MSG>;

export const textInput: (p0: ReadonlyArray<Attribute<MSG>>) => Node<MSG>;

export const view: (p0: ReadonlyArray<Attribute<MSG>>, p1: ReadonlyArray<Node<MSG>>) => Node<MSG>;

export type Attribute<MSG> = Attribute<MSG>;

export type Node<MSG> = Node<MSG>;

export type Program<FLAGS, MODEL, MSG> = Program<FLAGS, MODEL, MSG>;

