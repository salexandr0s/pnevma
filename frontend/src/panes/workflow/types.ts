export type LayoutNode = {
  id: string;
  label: string;
  stepIndex: number;
  status: string;
  x: number;
  y: number;
  width: number;
  height: number;
  layer: number;
};

export type LayoutEdge = {
  from: string;
  to: string;
  path: string;
};

export type DagLayout = {
  nodes: LayoutNode[];
  edges: LayoutEdge[];
  width: number;
  height: number;
};
