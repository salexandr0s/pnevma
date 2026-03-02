type ParsedShortcut = {
  requireMod: boolean;
  requireCtrl: boolean;
  requireMeta: boolean;
  requireAlt: boolean;
  requireShift: boolean;
  key: string | null;
};

function normalizeToken(token: string): string {
  return token.trim().toLowerCase();
}

function normalizeKeyToken(token: string): string {
  const lower = token.toLowerCase();
  if (lower === "arrowdown" || lower === "down") {
    return "arrowdown";
  }
  if (lower === "arrowup" || lower === "up") {
    return "arrowup";
  }
  if (lower === "arrowleft" || lower === "left") {
    return "arrowleft";
  }
  if (lower === "arrowright" || lower === "right") {
    return "arrowright";
  }
  if (lower === "esc") {
    return "escape";
  }
  if (lower === "space") {
    return " ";
  }
  if (lower === "return") {
    return "enter";
  }
  return lower;
}

function parseShortcut(shortcut: string): ParsedShortcut {
  const parsed: ParsedShortcut = {
    requireMod: false,
    requireCtrl: false,
    requireMeta: false,
    requireAlt: false,
    requireShift: false,
    key: null,
  };
  for (const raw of shortcut.split("+")) {
    const token = normalizeToken(raw);
    if (!token) {
      continue;
    }
    if (token === "mod") {
      parsed.requireMod = true;
      continue;
    }
    if (token === "ctrl" || token === "control") {
      parsed.requireCtrl = true;
      continue;
    }
    if (token === "cmd" || token === "meta") {
      parsed.requireMeta = true;
      continue;
    }
    if (token === "alt" || token === "option") {
      parsed.requireAlt = true;
      continue;
    }
    if (token === "shift") {
      parsed.requireShift = true;
      continue;
    }
    parsed.key = normalizeKeyToken(token);
  }
  return parsed;
}

export function matchesShortcut(event: KeyboardEvent, shortcut: string): boolean {
  const parsed = parseShortcut(shortcut);
  if (!parsed.requireMod && !parsed.requireCtrl && !parsed.requireMeta && (event.metaKey || event.ctrlKey)) {
    return false;
  }
  if (!parsed.requireAlt && event.altKey) {
    return false;
  }
  if (!parsed.requireShift && event.shiftKey && (parsed.key === null || parsed.key.length > 1)) {
    return false;
  }

  if (parsed.requireMod && !(event.metaKey || event.ctrlKey)) {
    return false;
  }
  if (parsed.requireCtrl && !event.ctrlKey) {
    return false;
  }
  if (parsed.requireMeta && !event.metaKey) {
    return false;
  }
  if (parsed.requireAlt && !event.altKey) {
    return false;
  }
  if (parsed.requireShift && !event.shiftKey) {
    return false;
  }

  if (parsed.key === null) {
    return true;
  }
  return normalizeKeyToken(event.key) === parsed.key;
}
