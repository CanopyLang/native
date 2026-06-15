export const on: (p0: string, p1: MSG) => Attribute<MSG>;

export const onChangeText: (p0: (p0: string) => MSG) => Attribute<MSG>;

export const onDoubleTap: (p0: MSG) => Attribute<MSG>;

export const onLongPress: (p0: MSG) => Attribute<MSG>;

export const onPan: (p0: (p0: { readonly dx: number; readonly dy: number; readonly vx: number; readonly vy: number }) => MSG) => Attribute<MSG>;

export const onPanEnd: (p0: (p0: { readonly dx: number; readonly dy: number; readonly vx: number; readonly vy: number }) => MSG) => Attribute<MSG>;

export const onPanStart: (p0: (p0: { readonly dx: number; readonly dy: number; readonly vx: number; readonly vy: number }) => MSG) => Attribute<MSG>;

export const onPress: (p0: MSG) => Attribute<MSG>;

export const onPressIn: (p0: MSG) => Attribute<MSG>;

export const onPressOut: (p0: MSG) => Attribute<MSG>;

export const onSubmitEditing: (p0: (p0: string) => MSG) => Attribute<MSG>;

export const onTap: (p0: MSG) => Attribute<MSG>;

export const onWithDecoder: (p0: string, p1: Decoder<MSG>) => Attribute<MSG>;

export const panDecoder: Decoder<{ readonly dx: number; readonly dy: number; readonly vx: number; readonly vy: number }>;

export type PanData = { readonly dx: number; readonly dy: number; readonly vx: number; readonly vy: number };

