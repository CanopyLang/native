/**
 * RND-5 — RN 0.76.9 side of the head-to-head benchmark.
 *
 * This is the byte-identical sibling of bench/rn-comparison/canopy/src/Main.can. Both render
 * the SAME three workloads (sourced from bench/rn-comparison/spec.json) so a side-by-side
 * measurement is apples-to-apples — the whole point of RND-5:
 *
 *   • "list"    — a 1000-row list via FlatList (RN's virtualized list). The Canopy side renders
 *                 the same 1000 rows via Native.List. Both are windowed; the fair comparison is
 *                 two windowing list impls, not FlatList vs a 1000-view dump.
 *   • "counter" — a single Int incremented per tap, re-rendering one <Text>. RN does a setState
 *                 re-render; Canopy does a targeted single-prop update.
 *   • "depth"   — 30 nested flex <View>s with one <Text> leaf, toggled on/off — a layout-depth +
 *                 cold-mount/teardown stress for Yoga.
 *
 * Every interactive node carries a STABLE testID + accessibilityLabel so scripts/bench-compare.sh
 * reaches the SAME selectors on both apps (RN maps accessibilityLabel → content-desc, the same
 * surface the Canopy host maps A.testID to). Colors, row count, row height, depth and font sizes
 * are read from spec.json at module load — change spec.json and BOTH apps move together.
 *
 * Target: React Native 0.76.9 (the version Canopy/native is ABI-pinned to — see vendor.lock.json).
 * This file uses only the core RN surface (View/Text/Pressable/FlatList/StyleSheet) that is
 * identical across 0.76.x, so it builds against a vanilla `npx @react-native-community/cli init`
 * 0.76.9 project with no extra deps.
 */

import React, { useCallback, useMemo, useState } from 'react';
import {
  View,
  Text,
  Pressable,
  FlatList,
  StyleSheet,
} from 'react-native';

import spec from '../spec.json';

const P = spec.palette;
const LIST = spec.workloads.list1000;
const DEPTH = spec.workloads.depth30;

// ---- shared selector helper: testID + accessibilityLabel so the scripted driver finds
// the node by content-desc on BOTH platforms (RN maps accessibilityLabel → content-desc). ----
const sel = (id) => ({
  testID: id,
  accessible: true,
  accessibilityLabel: id,
});

// ============================================================================
// WORKLOAD 1 — 1000-row list (FlatList)
// ============================================================================
function ListScreen() {
  const data = useMemo(
    () => Array.from({ length: LIST.rows }, (_, i) => i),
    [],
  );
  const [offset, setOffset] = useState(0);

  const renderItem = useCallback(({ item: n }) => {
    const even = n % 2 === 0;
    return (
      <View
        {...sel(`row-${n}`)}
        style={[
          styles.listRow,
          { backgroundColor: even ? P.rowEven : P.rowOdd },
        ]}
      >
        <Text style={styles.listRowText}>{`Item ${n}`}</Text>
      </View>
    );
  }, []);

  // Fixed-height rows → give FlatList getItemLayout so its windowing matches Native.List's
  // fixed-height window (apples-to-apples: both know the row height up front).
  const getItemLayout = useCallback(
    (_, index) => ({
      length: LIST.rowHeight,
      offset: LIST.rowHeight * index,
      index,
    }),
    [],
  );

  return (
    <View style={styles.flexOne}>
      <Text {...sel('list-header')} style={styles.listHeader}>
        {`offset ${Math.round(offset)}  ·  ${LIST.rows} rows`}
      </Text>
      <FlatList
        data={data}
        renderItem={renderItem}
        keyExtractor={(n) => String(n)}
        getItemLayout={getItemLayout}
        initialNumToRender={Math.ceil(spec.viewport.height / LIST.rowHeight) + LIST.overscan}
        windowSize={3}
        removeClippedSubviews
        onScroll={(e) => setOffset(e.nativeEvent.contentOffset.y)}
        scrollEventThrottle={16}
        style={styles.flexOne}
      />
    </View>
  );
}

// ============================================================================
// WORKLOAD 2 — counter (tap latency)
// ============================================================================
function CounterScreen() {
  const [count, setCount] = useState(0);
  return (
    <View style={[styles.flexOne, styles.center, { padding: 24 }]}>
      <Text {...sel('counter-label')} style={styles.counterLabel}>
        {`Count: ${count}`}
      </Text>
      <Pressable
        {...sel('increment')}
        style={[styles.btn, { backgroundColor: '#1e88e5', margin: 12 }]}
        onPress={() => setCount((c) => c + 1)}
      >
        <Text style={styles.btnText}>Tap me</Text>
      </Pressable>
      <Pressable
        {...sel('reset')}
        style={[styles.btn, { backgroundColor: '#37474f' }]}
        onPress={() => setCount(0)}
      >
        <Text style={styles.btnText}>Reset</Text>
      </Pressable>
    </View>
  );
}

// ============================================================================
// WORKLOAD 3 — depth-30 layout
// ============================================================================
function nested(n) {
  if (n <= 0) {
    return (
      <Text {...sel('depth-leaf')} style={styles.depthLeaf}>
        {`leaf @ depth ${DEPTH.depth}`}
      </Text>
    );
  }
  const even = n % 2 === 0;
  return (
    <View
      style={[
        styles.flexOne,
        { padding: 4, backgroundColor: even ? P.rowEven : P.rowOdd },
      ]}
    >
      {nested(n - 1)}
    </View>
  );
}

function DepthScreen() {
  const [shown, setShown] = useState(true);
  return (
    <View style={[styles.flexOne, { padding: 24 }]}>
      <Pressable
        {...sel('toggle-depth')}
        style={[styles.btn, { backgroundColor: P.accent, margin: 8 }]}
        onPress={() => setShown((s) => !s)}
      >
        <Text style={[styles.btnText, { color: P.bg }]}>Toggle depth-30 subtree</Text>
      </Pressable>
      {shown ? (
        nested(DEPTH.depth)
      ) : (
        <Text {...sel('depth-empty')} style={styles.depthEmpty}>
          (subtree unmounted)
        </Text>
      )}
    </View>
  );
}

// ============================================================================
// SHELL — tab bar selecting one of the three workloads
// ============================================================================
const SCREENS = {
  list: { label: 'List', tab: 'tab-list', Comp: ListScreen },
  counter: { label: 'Counter', tab: 'tab-counter', Comp: CounterScreen },
  depth: { label: 'Depth', tab: 'tab-depth', Comp: DepthScreen },
};

export default function App() {
  const [screen, setScreen] = useState('list');
  const Active = SCREENS[screen].Comp;
  return (
    <View style={[styles.flexOne, { backgroundColor: P.bg, paddingTop: 64 }]}>
      <View style={styles.tabBar}>
        {Object.entries(SCREENS).map(([key, s]) => (
          <Pressable
            key={key}
            {...sel(s.tab)}
            style={[
              styles.tab,
              { backgroundColor: screen === key ? P.accent : '#2A2A2E' },
            ]}
            onPress={() => setScreen(key)}
          >
            <Text style={styles.tabText}>{s.label}</Text>
          </Pressable>
        ))}
      </View>
      <Active />
    </View>
  );
}

const styles = StyleSheet.create({
  flexOne: { flex: 1 },
  center: { justifyContent: 'center', alignItems: 'center' },
  tabBar: { flexDirection: 'row', backgroundColor: P.rowEven, padding: 8 },
  tab: { padding: 12, borderRadius: 10, margin: 4 },
  tabText: { color: P.text, fontSize: 14 },
  listHeader: { fontSize: 18, color: P.accent, padding: 16 },
  listRow: { height: LIST.rowHeight, justifyContent: 'center', paddingLeft: 20 },
  listRowText: { fontSize: LIST.fontSize, color: P.text },
  counterLabel: { fontSize: spec.workloads.counter.fontSize, color: P.text, padding: 24 },
  btn: { padding: 16, borderRadius: 12 },
  btnText: { color: '#FFFFFF', fontSize: 16 },
  depthLeaf: { fontSize: DEPTH.leafFontSize, color: P.text },
  depthEmpty: { fontSize: 16, color: P.muted, padding: 12 },
});
