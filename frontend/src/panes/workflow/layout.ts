import type { LayoutNode, LayoutEdge, DagLayout } from "./types";
import { NODE_WIDTH, NODE_HEIGHT, LAYER_GAP_X, NODE_GAP_Y, PADDING } from "./constants";

export type StepInput = {
  id: string;
  title: string;
  status: string;
  dependsOn: number[];
};

export function computeDagLayout(steps: StepInput[]): DagLayout {
  if (steps.length === 0) return { nodes: [], edges: [], width: 0, height: 0 };

  // Layer assignment via longest path from sources
  const layers = new Array<number>(steps.length).fill(0);
  const visited = new Set<number>();

  function assignLayer(idx: number): number {
    if (visited.has(idx)) return layers[idx];
    visited.add(idx);
    let maxDepLayer = -1;
    for (const dep of steps[idx].dependsOn) {
      maxDepLayer = Math.max(maxDepLayer, assignLayer(dep));
    }
    layers[idx] = maxDepLayer + 1;
    return layers[idx];
  }

  for (let i = 0; i < steps.length; i++) assignLayer(i);

  // Group by layer
  const maxLayer = Math.max(...layers);
  const layerGroups: number[][] = Array.from({ length: maxLayer + 1 }, () => []);
  for (let i = 0; i < steps.length; i++) {
    layerGroups[layers[i]].push(i);
  }

  // Assign coordinates
  const nodes: LayoutNode[] = [];
  for (let layer = 0; layer <= maxLayer; layer++) {
    const group = layerGroups[layer];
    const x = PADDING + layer * (NODE_WIDTH + LAYER_GAP_X);
    for (let j = 0; j < group.length; j++) {
      const idx = group[j];
      const y = PADDING + j * (NODE_HEIGHT + NODE_GAP_Y);
      nodes.push({
        id: steps[idx].id,
        label: steps[idx].title,
        stepIndex: idx,
        status: steps[idx].status,
        x,
        y,
        width: NODE_WIDTH,
        height: NODE_HEIGHT,
        layer,
      });
    }
  }

  // Build edges
  const nodeMap = new Map(nodes.map((n) => [n.stepIndex, n]));
  const edges: LayoutEdge[] = [];
  for (const step of steps) {
    const to = nodeMap.get(steps.indexOf(step));
    if (!to) continue;
    for (const depIdx of step.dependsOn) {
      const from = nodeMap.get(depIdx);
      if (!from) continue;
      const x1 = from.x + from.width;
      const y1 = from.y + from.height / 2;
      const x2 = to.x;
      const y2 = to.y + to.height / 2;
      const cx = (x1 + x2) / 2;
      const path = `M ${x1} ${y1} C ${cx} ${y1}, ${cx} ${y2}, ${x2} ${y2}`;
      edges.push({ from: from.id, to: to.id, path });
    }
  }

  const width = PADDING * 2 + (maxLayer + 1) * (NODE_WIDTH + LAYER_GAP_X) - LAYER_GAP_X;
  const maxNodesInLayer = Math.max(...layerGroups.map((g) => g.length));
  const height = PADDING * 2 + maxNodesInLayer * (NODE_HEIGHT + NODE_GAP_Y) - NODE_GAP_Y;

  return { nodes, edges, width, height };
}
