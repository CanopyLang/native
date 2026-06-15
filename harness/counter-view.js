// counter-view.js — a faithful hand-port of examples/counter/src/Main.can plus the
// slices of VirtualDom / Native / Native.Attributes / Native.Events it uses, written
// to emit the EXACT vnode data the Canopy compiler would emit (same `$` tags, same
// `__facts` buckets produced by organizeFacts, same array kids). This lets the
// harness drive the REAL external/native.js walker on REAL-shaped input without the
// compiler installed.
//
// When the compiler is built, examples/counter compiles to a bundle whose `view`
// produces byte-for-byte these same structures; this file is the stand-in until then.

'use strict';

// ---- VirtualDom node tags (must match native.js / virtual-dom.js) ----------
const TEXT = 0, NODE = 1, KEYED_NODE = 2, TAGGER = 4;

// ---- VirtualDom fact constructors ------------------------------------------
const style = (k, v) => ({ $: 'a__1_STYLE', __key: k, __value: v });
const attribute = (k, v) => ({ $: 'a__1_ATTR', __key: k, __value: v });
const property = (k, v) => ({ $: 'a__1_PROP', __key: k, __value: v });
const onEvent = (event, handler) => ({ $: 'a__1_EVENT', __key: event, __value: handler });
const Normal = (decoder) => ({ $: 'Normal', a: decoder });

// ---- a faithful organizeFacts (mirror of _VirtualDom_organizeFacts) --------
function organizeFacts(factList) {
    const facts = {};
    for (const entry of factList) {
        const tag = entry.$, key = entry.__key, value = entry.__value;
        if (tag === 'a__1_PROP') { facts[key] = value; continue; }
        const sub = facts[tag] || (facts[tag] = {});
        sub[key] = value;
    }
    return facts;
}

// ---- VirtualDom node builders ----------------------------------------------
const vtext = (s) => ({ $: TEXT, __text: s });
const node = (tag, attrs, kids) => ({
    $: NODE, __tag: tag, __facts: organizeFacts(attrs), __kids: kids, __namespace: undefined,
});

// ---- Json.Decode shim (decoder tags understood by mini-runtime._Json_runHelp)
const Json = {
    succeed: (v) => ({ tag: 'succeed', value: v }),
    string: { tag: 'string' },
    field: (k, d) => ({ tag: 'field', key: k, decoder: d }),
    map: (fn, d) => ({ tag: 'map', fn, decoder: d }),
};

// ---- Native.Attributes port -------------------------------------------------
const A = {
    style,
    padding: (n) => style('padding', String(n)),
    margin: (n) => style('margin', String(n)),
    fontSize: (n) => style('fontSize', String(n)),
    backgroundColor: (s) => style('backgroundColor', s),
    color: (s) => style('color', s),
    flex: (n) => style('flex', String(n)),
    justifyContent: (s) => style('justifyContent', s),
    borderRadius: (n) => style('borderRadius', String(n)),
    accessibilityRole: (s) => attribute('accessibilityRole', s),
    testID: (s) => attribute('testID', s),
};

// ---- Native.Events port -----------------------------------------------------
const Events = {
    onPress: (msg) => onEvent('press', Normal(Json.succeed(msg))),
    onChangeText: (tagger) => onEvent('changeText', Normal(Json.map(tagger, Json.field('text', Json.string)))),
};

// ---- Native view-constructor port ------------------------------------------
const Native = {
    column: (attrs, kids) => node('RCTView', [style('flexDirection', 'column'), ...attrs], kids),
    row: (attrs, kids) => node('RCTView', [style('flexDirection', 'row'), ...attrs], kids),
    text: (attrs, str) => node('RCTText', attrs, [vtext(str)]),
    pressable: (attrs, kids) => node('RCTView', [attribute('accessibilityRole', 'button'), ...attrs], kids),
    button: (attrs, label) => Native.pressable(attrs, [Native.text([], label)]),
    textInput: (attrs) => node('RCTSinglelineTextInputView', attrs, []),
};

// ============================================================================
// The app — a 1:1 port of examples/counter/src/Main.can
// ============================================================================

const cmdNone = { $: '[]' };       // Cmd.none placeholder (effects unused by the wedge)
const subNone = { $: '[]' };       // Sub.none placeholder

const Msg = { Increment: { $: 'Increment' }, Reset: { $: 'Reset' } };

const init = (_flags) => ({ a: 0, b: cmdNone });

const update = globalThis.F2((msg, model) => {
    switch (msg.$) {
        case 'Increment': return { a: model + 1, b: cmdNone };
        case 'Reset':     return { a: 0, b: cmdNone };
        default:          return { a: model, b: cmdNone };
    }
});

function view(model) {
    return Native.column(
        [A.padding(24), A.backgroundColor('#0b1020'), A.flex(1), A.justifyContent('center')],
        [
            Native.text([A.fontSize(28), A.color('#e8ecff')], 'Count: ' + String(model)),
            Native.button(
                [Events.onPress(Msg.Increment), A.testID('increment'),
                 A.backgroundColor('#1e88e5'), A.padding(16), A.borderRadius(12), A.margin(12)],
                'Tap me'
            ),
            Native.button(
                [Events.onPress(Msg.Reset), A.testID('reset'),
                 A.backgroundColor('#37474f'), A.padding(16), A.borderRadius(12)],
                'Reset'
            ),
        ]
    );
}

const subscriptions = (_model) => subNone;

module.exports = {
    app: { init, view, update, subscriptions },
    builders: { Native, A, Events, Json, node, vtext, organizeFacts },
};
