/**
 * P3a 只读 HTML 查询桥。
 *
 * 上游 Rust 使用 dom_query，支持完整 CSS 选择器。鸿蒙 pilot 这里实现一个
 * 无依赖的只读子集：tag / .class / #id / [attr] / [attr=value]，组合子支持
 * 后代（空格）和子代（>），多组选择器用逗号分隔。返回契约与上游一致：
 * text / html / attrs，最多 200 条。
 *
 * 安全边界：只解析输入文本，不执行脚本，不访问网络和文件；HTML 与选择器
 * 都加上限，避免解析炸弹。
 */
import { util } from '@kit.ArkTS';

const MAX_HTML_BYTES = 2 * 1024 * 1024;
const MAX_HTML_RESULTS = 200;
const MAX_HTML_NODES = 50000;
const MAX_SELECTOR_LENGTH = 256;

const NODE_ELEMENT = 0;
const NODE_TEXT = 1;

const COMBINATOR_NONE = 0;
const COMBINATOR_DESCENDANT = 1;
const COMBINATOR_CHILD = 2;

const CONDITION_ANY = 0;
const CONDITION_TAG = 1;
const CONDITION_ID = 2;
const CONDITION_CLASS = 3;
const CONDITION_ATTR = 4;
const CONDITION_ATTR_VALUE = 5;

export interface SourceHtmlAttr {
  name: string;
  value: string;
}

export interface SourceHtmlItem {
  text: string;
  html: string;
  attrs: Record<string, string>;
}

class HtmlNode {
  kind: number = NODE_ELEMENT;
  tag: string = '';
  attrs: SourceHtmlAttr[] = [];
  children: HtmlNode[] = [];
  text: string = '';
  parent: HtmlNode | null = null;
  selfClosing: boolean = false;
}

class SelectorCondition {
  type: number = CONDITION_TAG;
  tag: string = '';
  id: string = '';
  cls: string = '';
  attrName: string = '';
  attrValue: string = '';
}

class SelectorCompound {
  conditions: SelectorCondition[] = [];
}

class SelectorSequence {
  combinator: number = COMBINATOR_NONE;
  compound: SelectorCompound = new SelectorCompound();
}

interface OpenTagResult {
  node: HtmlNode;
  next: number;
  selfClosing: boolean;
}

interface AttributeResult {
  attr: SourceHtmlAttr;
  next: number;
}

interface ScanResult {
  text: string;
  next: number;
}

interface AttrConditionResult {
  condition: SelectorCondition;
  next: number;
}

function byteLength(text: string): number {
  const encoded = new util.TextEncoder().encodeInto(text);
  return encoded.byteLength;
}

function isSpaceChar(ch: string): boolean {
  return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === '\f';
}

function decodeEntities(text: string): string {
  let out = text;
  out = replaceAll(out, '&amp;', '&');
  out = replaceAll(out, '&lt;', '<');
  out = replaceAll(out, '&gt;', '>');
  out = replaceAll(out, '&quot;', '"');
  out = replaceAll(out, '&#39;', '\'');
  out = replaceAll(out, '&apos;', '\'');
  out = replaceAll(out, '&nbsp;', ' ');
  return out;
}

function replaceAll(text: string, from: string, to: string): string {
  if (from.length === 0) {
    return text;
  }
  let out = '';
  let i = 0;
  while (i < text.length) {
    const hit = text.indexOf(from, i);
    if (hit < 0) {
      out += text.substring(i);
      break;
    }
    out += text.substring(i, hit) + to;
    i = hit + from.length;
  }
  return out;
}

function escapeHtml(text: string): string {
  let out = '';
  for (let i = 0; i < text.length; i++) {
    const ch = text.charAt(i);
    if (ch === '&') {
      out += '&amp;';
    } else if (ch === '<') {
      out += '&lt;';
    } else if (ch === '>') {
      out += '&gt;';
    } else if (ch === '"') {
      out += '&quot;';
    } else {
      out += ch;
    }
  }
  return out;
}

function isVoidTag(tag: string): boolean {
  const voidTags: string[] = ['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'];
  for (const item of voidTags) {
    if (item === tag) {
      return true;
    }
  }
  return false;
}

function isRawTextTag(tag: string): boolean {
  return tag === 'script' || tag === 'style';
}

export class SourceHtml {
  query(html: string, selector: string): string {
    if (byteLength(html) > MAX_HTML_BYTES) {
      throw new Error('HTML 文本超出解析上限（2 MB）');
    }
    const trimmedSelector = selector.trim();
    if (trimmedSelector.length === 0 || trimmedSelector.length > MAX_SELECTOR_LENGTH) {
      throw new Error('CSS 选择器无效');
    }
    const root = this.parseHtml(html);
    const alternatives = this.parseSelector(trimmedSelector);
    const items: SourceHtmlItem[] = [];
    this.collect(root, alternatives, items);
    return JSON.stringify(items);
  }

  private collect(root: HtmlNode, alternatives: SelectorSequence[][], items: SourceHtmlItem[]): void {
    const queue: HtmlNode[] = [];
    for (const child of root.children) {
      queue.push(child);
    }
    let cursor = 0;
    while (cursor < queue.length) {
      const node = queue[cursor];
      cursor++;
      if (node.kind === NODE_ELEMENT && node.tag !== '#document') {
        if (this.matchesAny(node, alternatives)) {
          if (items.length >= MAX_HTML_RESULTS) {
            return;
          }
          items.push(this.toItem(node));
        }
      }
      for (const child of node.children) {
        queue.push(child);
      }
    }
  }

  private toItem(node: HtmlNode): SourceHtmlItem {
    const attrs: Record<string, string> = {};
    for (const attr of node.attrs) {
      attrs[attr.name] = attr.value;
    }
    return {
      text: this.textContent(node),
      html: this.innerHtml(node),
      attrs: attrs
    };
  }

  private textContent(node: HtmlNode): string {
    if (node.kind === NODE_TEXT) {
      return node.text;
    }
    let out = '';
    for (const child of node.children) {
      out += this.textContent(child);
    }
    return out;
  }

  private innerHtml(node: HtmlNode): string {
    let out = '';
    for (const child of node.children) {
      out += this.serializeNode(child);
    }
    return out;
  }

  private serializeNode(node: HtmlNode): string {
    if (node.kind === NODE_TEXT) {
      return escapeHtml(node.text);
    }
    let out = '<' + node.tag;
    for (const attr of node.attrs) {
      out += ' ' + attr.name + '="' + escapeHtml(attr.value) + '"';
    }
    if (isVoidTag(node.tag)) {
      return out + '>';
    }
    return out + '>' + this.innerHtml(node) + '</' + node.tag + '>';
  }

  private matchesAny(node: HtmlNode, alternatives: SelectorSequence[][]): boolean {
    for (const sequence of alternatives) {
      if (this.matchesSequence(node, sequence)) {
        return true;
      }
    }
    return false;
  }

  private matchesSequence(node: HtmlNode, sequence: SelectorSequence[]): boolean {
    let current: HtmlNode | null = node;
    for (let i = sequence.length - 1; i >= 1; i--) {
      if (current === null || current.kind !== NODE_ELEMENT) {
        return false;
      }
      if (!this.matchesCompound(current, sequence[i].compound)) {
        return false;
      }
      const combinator = sequence[i].combinator;
      if (combinator === COMBINATOR_CHILD) {
        current = current.parent;
        if (current === null || current.kind !== NODE_ELEMENT || current.tag === '#document') {
          return false;
        }
      } else {
        let ancestor: HtmlNode | null = current.parent;
        let matched = false;
        while (ancestor !== null && ancestor.kind === NODE_ELEMENT && ancestor.tag !== '#document') {
          if (this.matchesCompound(ancestor, sequence[i - 1].compound)) {
            current = ancestor;
            matched = true;
            break;
          }
          ancestor = ancestor.parent;
        }
        if (!matched) {
          return false;
        }
      }
    }
    return current !== null && current.kind === NODE_ELEMENT && this.matchesCompound(current, sequence[0].compound);
  }

  private matchesCompound(node: HtmlNode, compound: SelectorCompound): boolean {
    for (const condition of compound.conditions) {
      if (!this.matchesCondition(node, condition)) {
        return false;
      }
    }
    return true;
  }

  private matchesCondition(node: HtmlNode, condition: SelectorCondition): boolean {
    if (condition.type === CONDITION_ANY) {
      return true;
    }
    if (condition.type === CONDITION_TAG) {
      return node.tag === condition.tag;
    }
    if (condition.type === CONDITION_ID) {
      return this.attrValue(node, 'id') === condition.id;
    }
    if (condition.type === CONDITION_CLASS) {
      return this.hasClass(node, condition.cls);
    }
    const value = this.attrValue(node, condition.attrName);
    if (value === null) {
      return false;
    }
    if (condition.type === CONDITION_ATTR) {
      return true;
    }
    return value === condition.attrValue;
  }

  private attrValue(node: HtmlNode, name: string): string | null {
    for (const attr of node.attrs) {
      if (attr.name === name) {
        return attr.value;
      }
    }
    return null;
  }

  private hasClass(node: HtmlNode, name: string): boolean {
    const value = this.attrValue(node, 'class');
    if (value === null) {
      return false;
    }
    const parts = value.split(' ');
    for (const part of parts) {
      if (part === name) {
        return true;
      }
    }
    return false;
  }

  private parseHtml(input: string): HtmlNode {
    const root = new HtmlNode();
    root.kind = NODE_ELEMENT;
    root.tag = '#document';
    const stack: HtmlNode[] = [root];
    let nodeCount = 1;
    let i = 0;
    while (i < input.length) {
      const lt = input.indexOf('<', i);
      if (lt < 0) {
        this.appendText(stack[stack.length - 1], input.substring(i), nodeCount);
        break;
      }
      if (lt > i) {
        nodeCount = this.appendText(stack[stack.length - 1], input.substring(i, lt), nodeCount);
      }
      if (this.startsWith(input, lt, '<!--')) {
        const end = input.indexOf('-->', lt + 4);
        i = end < 0 ? input.length : end + 3;
        continue;
      }
      if (this.startsWith(input, lt, '<!') || this.startsWith(input, lt, '<?')) {
        const end = input.indexOf('>', lt);
        i = end < 0 ? input.length : end + 1;
        continue;
      }
      if (this.startsWith(input, lt, '</')) {
        const end = this.findTagEnd(input, lt);
        const name = this.readClosingName(input, lt);
        this.popElement(stack, name);
        i = end < 0 ? input.length : end + 1;
        continue;
      }
      const open = this.readOpenTag(input, lt);
      if (open === null) {
        nodeCount = this.appendText(stack[stack.length - 1], '<', nodeCount);
        i = lt + 1;
        continue;
      }
      open.node.selfClosing = open.selfClosing;
      nodeCount = this.appendElement(stack, open.node, nodeCount);
      i = open.next;
      if (isRawTextTag(open.node.tag) && !open.selfClosing) {
        const closeStart = this.findRawTextClose(input, i, open.node.tag);
        if (closeStart < 0) {
          nodeCount = this.appendText(stack[stack.length - 1], input.substring(i), nodeCount);
          this.popElement(stack, open.node.tag);
          i = input.length;
        } else {
          nodeCount = this.appendText(stack[stack.length - 1], input.substring(i, closeStart), nodeCount);
          const closeEnd = this.findTagEnd(input, closeStart);
          this.popElement(stack, open.node.tag);
          i = closeEnd < 0 ? input.length : closeEnd + 1;
        }
      }
      if (nodeCount > MAX_HTML_NODES) {
        throw new Error('HTML 节点数超出 pilot 解析上限');
      }
    }
    return root;
  }

  private appendText(parent: HtmlNode, text: string, nodeCount: number): number {
    if (text.length === 0) {
      return nodeCount;
    }
    const node = new HtmlNode();
    node.kind = NODE_TEXT;
    node.text = decodeEntities(text);
    node.parent = parent;
    parent.children.push(node);
    return nodeCount + 1;
  }

  private appendElement(stack: HtmlNode[], node: HtmlNode, nodeCount: number): number {
    const parent = stack[stack.length - 1];
    node.parent = parent;
    parent.children.push(node);
    if (!isVoidTag(node.tag) && !node.selfClosing) {
      stack.push(node);
    }
    return nodeCount + 1;
  }

  private popElement(stack: HtmlNode[], name: string): void {
    if (name.length === 0) {
      return;
    }
    for (let i = stack.length - 1; i >= 1; i--) {
      if (stack[i].tag === name) {
        while (stack.length > i) {
          stack.pop();
        }
        return;
      }
    }
  }

  private readOpenTag(input: string, lt: number): OpenTagResult | null {
    let i = lt + 1;
    while (i < input.length && isSpaceChar(input.charAt(i))) {
      i++;
    }
    const nameStart = i;
    while (i < input.length) {
      const ch = input.charAt(i);
      if (isSpaceChar(ch) || ch === '>' || ch === '/') {
        break;
      }
      i++;
    }
    const tag = input.substring(nameStart, i).toLowerCase();
    if (tag.length === 0) {
      return null;
    }
    const node = new HtmlNode();
    node.kind = NODE_ELEMENT;
    node.tag = tag;
    let selfClosing = false;
    while (i < input.length) {
      while (i < input.length && isSpaceChar(input.charAt(i))) {
        i++;
      }
      if (i >= input.length) {
        break;
      }
      const ch = input.charAt(i);
      if (ch === '>') {
        i++;
        break;
      }
      if (ch === '/') {
        selfClosing = true;
        i++;
        continue;
      }
      const attr = this.readAttribute(input, i);
      if (attr === null) {
        i++;
        continue;
      }
      node.attrs.push(attr.attr);
      i = attr.next;
    }
    return { node: node, next: i, selfClosing: selfClosing };
  }

  private readAttribute(input: string, start: number): AttributeResult | null {
    let i = start;
    while (i < input.length && isSpaceChar(input.charAt(i))) {
      i++;
    }
    const nameStart = i;
    while (i < input.length) {
      const ch = input.charAt(i);
      if (isSpaceChar(ch) || ch === '=' || ch === '>' || ch === '/') {
        break;
      }
      i++;
    }
    const name = input.substring(nameStart, i).toLowerCase();
    if (name.length === 0) {
      return null;
    }
    let value = '';
    let j = i;
    while (j < input.length && isSpaceChar(input.charAt(j))) {
      j++;
    }
    if (j < input.length && input.charAt(j) === '=') {
      j++;
      while (j < input.length && isSpaceChar(input.charAt(j))) {
        j++;
      }
      if (j < input.length && (input.charAt(j) === '"' || input.charAt(j) === '\'')) {
        const quote = input.charAt(j);
        j++;
        const valueStart = j;
        while (j < input.length && input.charAt(j) !== quote) {
          j++;
        }
        value = decodeEntities(input.substring(valueStart, j));
        if (j < input.length) {
          j++;
        }
      } else {
        const valueStart = j;
        while (j < input.length) {
          const ch = input.charAt(j);
          if (isSpaceChar(ch) || ch === '>') {
            break;
          }
          j++;
        }
        value = decodeEntities(input.substring(valueStart, j));
      }
      i = j;
    }
    const parsed: SourceHtmlAttr = { name: name, value: value };
    return { attr: parsed, next: i };
  }

  private findTagEnd(input: string, lt: number): number {
    let quote = '';
    for (let i = lt; i < input.length; i++) {
      const ch = input.charAt(i);
      if (quote.length > 0) {
        if (ch === quote) {
          quote = '';
        }
        continue;
      }
      if (ch === '"' || ch === '\'') {
        quote = ch;
        continue;
      }
      if (ch === '>') {
        return i;
      }
    }
    return -1;
  }

  private readClosingName(input: string, lt: number): string {
    let i = lt + 2;
    while (i < input.length && isSpaceChar(input.charAt(i))) {
      i++;
    }
    const start = i;
    while (i < input.length) {
      const ch = input.charAt(i);
      if (isSpaceChar(ch) || ch === '>') {
        break;
      }
      i++;
    }
    return input.substring(start, i).toLowerCase();
  }

  private findRawTextClose(input: string, start: number, tag: string): number {
    const needle = '</' + tag;
    let i = start;
    while (i < input.length) {
      const hit = input.indexOf(needle, i);
      if (hit < 0) {
        return -1;
      }
      const after = hit + needle.length;
      if (after >= input.length || input.charAt(after) === '>' || isSpaceChar(input.charAt(after)) || input.charAt(after) === '/') {
        return hit;
      }
      i = hit + 1;
    }
    return -1;
  }

  private startsWith(input: string, at: number, prefix: string): boolean {
    if (at + prefix.length > input.length) {
      return false;
    }
    return input.substring(at, at + prefix.length) === prefix;
  }

  private parseSelector(selector: string): SelectorSequence[][] {
    const alternatives: SelectorSequence[][] = [];
    const parts = selector.split(',');
    for (const part of parts) {
      const sequence = this.parseSelectorSequence(part);
      if (sequence.length > 0) {
        alternatives.push(sequence);
      }
    }
    if (alternatives.length === 0) {
      throw new Error('CSS 选择器无效');
    }
    return alternatives;
  }

  private parseSelectorSequence(part: string): SelectorSequence[] {
    const sequences: SelectorSequence[] = [];
    let i = 0;
    let combinator = COMBINATOR_NONE;
    while (i < part.length) {
      while (i < part.length && isSpaceChar(part.charAt(i))) {
        i++;
        if (sequences.length > 0) {
          combinator = COMBINATOR_DESCENDANT;
        }
      }
      if (i >= part.length) {
        break;
      }
      if (part.charAt(i) === '>') {
        combinator = COMBINATOR_CHILD;
        i++;
        while (i < part.length && isSpaceChar(part.charAt(i))) {
          i++;
        }
        if (i >= part.length) {
          break;
        }
      }
      const compound = this.readSelectorCompound(part, i);
      if (compound.text.length === 0) {
        break;
      }
      const sequence = new SelectorSequence();
      sequence.combinator = sequences.length === 0 ? COMBINATOR_NONE : combinator;
      sequence.compound = this.parseCompound(compound.text);
      sequences.push(sequence);
      combinator = COMBINATOR_DESCENDANT;
      i = compound.next;
    }
    return sequences;
  }

  private readSelectorCompound(part: string, start: number): ScanResult {
    let depth = 0;
    let quote = '';
    let i = start;
    while (i < part.length) {
      const ch = part.charAt(i);
      if (quote.length > 0) {
        if (ch === quote) {
          quote = '';
        }
        i++;
        continue;
      }
      if (ch === '"' || ch === '\'') {
        quote = ch;
        i++;
        continue;
      }
      if (ch === '[') {
        depth++;
        i++;
        continue;
      }
      if (ch === ']') {
        depth--;
        i++;
        continue;
      }
      if (depth === 0 && (isSpaceChar(ch) || ch === '>')) {
        break;
      }
      i++;
    }
    return { text: part.substring(start, i), next: i };
  }

  private parseCompound(text: string): SelectorCompound {
    const compound = new SelectorCompound();
    let tag = '';
    let i = 0;
    while (i < text.length) {
      const ch = text.charAt(i);
      if (ch === '*') {
        const condition = new SelectorCondition();
        condition.type = CONDITION_ANY;
        compound.conditions.push(condition);
        i++;
      } else if (ch === '#') {
        const ident = this.readIdent(text, i + 1);
        const condition = new SelectorCondition();
        condition.type = CONDITION_ID;
        condition.id = decodeEntities(ident.text);
        compound.conditions.push(condition);
        i = ident.next;
      } else if (ch === '.') {
        const ident = this.readIdent(text, i + 1);
        const condition = new SelectorCondition();
        condition.type = CONDITION_CLASS;
        condition.cls = decodeEntities(ident.text);
        compound.conditions.push(condition);
        i = ident.next;
      } else if (ch === '[') {
        const attr = this.readAttrCondition(text, i);
        if (attr === null) {
          break;
        }
        compound.conditions.push(attr.condition);
        i = attr.next;
      } else {
        const ident = this.readIdent(text, i);
        if (ident.text.length === 0) {
          i++;
          continue;
        }
        tag = ident.text.toLowerCase();
        i = ident.next;
      }
    }
    if (tag.length > 0) {
      const condition = new SelectorCondition();
      condition.type = CONDITION_TAG;
      condition.tag = tag;
      compound.conditions.unshift(condition);
    }
    if (compound.conditions.length === 0) {
      throw new Error('CSS 选择器无效');
    }
    return compound;
  }

  private readIdent(text: string, start: number): ScanResult {
    let i = start;
    while (i < text.length) {
      const ch = text.charAt(i);
      if (isSpaceChar(ch) || ch === '#' || ch === '.' || ch === '[' || ch === ']' || ch === '>' || ch === ',') {
        break;
      }
      i++;
    }
    return { text: text.substring(start, i), next: i };
  }

  private readAttrCondition(text: string, start: number): AttrConditionResult | null {
    let i = start + 1;
    let quote = '';
    let depth = 1;
    const nameStart = i;
    let eq = -1;
    while (i < text.length) {
      const ch = text.charAt(i);
      if (quote.length > 0) {
        if (ch === quote) {
          quote = '';
        }
        i++;
        continue;
      }
      if (ch === '"' || ch === '\'') {
        quote = ch;
        i++;
        continue;
      }
      if (ch === '[') {
        depth++;
        i++;
        continue;
      }
      if (ch === ']') {
        depth--;
        if (depth === 0) {
          break;
        }
        i++;
        continue;
      }
      if (ch === '=' && eq < 0 && depth === 1) {
        eq = i;
      }
      i++;
    }
    if (i >= text.length) {
      return null;
    }
    const close = i;
    if (eq < 0) {
      const condition = new SelectorCondition();
      condition.type = CONDITION_ATTR;
      condition.attrName = text.substring(nameStart, close).trim().toLowerCase();
      if (condition.attrName.length === 0) {
        return null;
      }
      return { condition: condition, next: close + 1 };
    }
    const condition = new SelectorCondition();
    condition.type = CONDITION_ATTR_VALUE;
    condition.attrName = text.substring(nameStart, eq).trim().toLowerCase();
    let value = text.substring(eq + 1, close).trim();
    if (value.length >= 2 && (value.charAt(0) === '"' || value.charAt(0) === '\'') && value.charAt(value.length - 1) === value.charAt(0)) {
      value = value.substring(1, value.length - 1);
    }
    condition.attrValue = decodeEntities(value);
    if (condition.attrName.length === 0) {
      return null;
    }
    return { condition: condition, next: close + 1 };
  }
}
