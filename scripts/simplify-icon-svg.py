#!/usr/bin/env python3
"""
图标 SVG 几何简化：把复杂路径的锚点数压到目标预算内（应对 TOS 商店「≤50 nodes」审核）。

做法：M/C/L/Q/Z 绝对指令解析 → 曲线密集采样 → Ramer–Douglas–Peucker 简化
      → 烘焙 <g> 的 translate/scale → 输出 M/L/Z 路径（保留 evenodd 填充规则）。

用法：simplify-icon-svg.py <输入.svg> <输出.svg> [锚点预算=40]
"""
import re
import sys
import math


def parse_path(d):
    """解析绝对指令 M/L/C/Q/Z，返回子路径列表（subpath = list[(x, y)]），C/Q 已采样。"""
    tokens = re.findall(r'[MLCQZmlcqz]|-?[\d.]+(?:e-?\d+)?', d)
    i = 0
    subs, cur, start, pos = [], [], None, (0.0, 0.0)
    cmd = None
    def num():
        nonlocal i
        v = float(tokens[i]); i += 1
        return v
    while i < len(tokens):
        t = tokens[i]
        if re.match(r'[MLCQZmlcqz]', t):
            cmd = t; i += 1
            if cmd in 'Zz':
                if cur:
                    cur.append(start); subs.append(cur); cur = []
                continue
        if cmd in ('M', 'L', 'm', 'l'):
            x, y = num(), num()
            if cmd in ('m', 'l'):
                x, y = pos[0] + x, pos[1] + y
            pos = (x, y)
            if cmd in ('M', 'm'):
                if cur:
                    subs.append(cur)
                cur, start = [(x, y)], (x, y)
            else:
                cur.append((x, y))
        elif cmd in ('C', 'c'):
            p1 = (num(), num()); p2 = (num(), num()); p3 = (num(), num())
            if cmd == 'c':
                p1 = (pos[0] + p1[0], pos[1] + p1[1])
                p2 = (pos[0] + p2[0], pos[1] + p2[1])
                p3 = (pos[0] + p3[0], pos[1] + p3[1])
            for k in range(1, 13):  # 每条三次曲线采 12 点
                u = k / 12.0
                b = lambda a, b_, c, dd: ((1-u)**3)*a + 3*((1-u)**2)*u*b_ + 3*(1-u)*(u**2)*c + (u**3)*dd
                cur.append((b(pos[0], p1[0], p2[0], p3[0]), b(pos[1], p1[1], p2[1], p3[1])))
            pos = p3
        elif cmd in ('Q', 'q'):
            p1 = (num(), num()); p2 = (num(), num())
            if cmd == 'q':
                p1 = (pos[0] + p1[0], pos[1] + p1[1]); p2 = (pos[0] + p2[0], pos[1] + p2[1])
            for k in range(1, 13):
                u = k / 12.0
                b = lambda a, b_, c: ((1-u)**2)*a + 2*(1-u)*u*b_ + (u**2)*c
                cur.append((b(pos[0], p1[0], p2[0]), b(pos[1], p1[1], p2[1])))
            pos = p2
    if cur:
        subs.append(cur)
    return subs


def rdp(points, eps):
    """Ramer–Douglas–Peucker 折线简化。"""
    if len(points) < 3:
        return points
    (x1, y1), (x2, y2) = points[0], points[-1]
    dmax, idx = 0.0, 0
    dx, dy = x2 - x1, y2 - y1
    norm = math.hypot(dx, dy)
    for i in range(1, len(points) - 1):
        px, py = points[i]
        dist = abs(dy * px - dx * py + x2 * y1 - y2 * x1) / norm if norm else math.hypot(px - x1, py - y1)
        if dist > dmax:
            dmax, idx = dist, i
    if dmax > eps:
        left = rdp(points[:idx + 1], eps)
        right = rdp(points[idx:], eps)
        return left[:-1] + right
    return [points[0], points[-1]]


def count_anchors(subs):
    return sum(len(s) for s in subs)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    budget = int(sys.argv[3]) if len(sys.argv) > 3 else 40
    svg = open(src, encoding='utf-8').read()

    m = re.search(r'\sd="([^"]+)"', svg)
    if not m:
        print('未找到 path d', file=sys.stderr); sys.exit(1)
    subs = parse_path(m.group(1))
    print(f'原始：{count_anchors(subs)} 锚点 / {len(subs)} 子路径')

    # 解析并烘焙外层 <g> 的 translate/scale
    g = re.search(r'<g[^>]*transform="([^"]+)"', svg)
    tx = ty = 0.0; sc = 1.0
    if g:
        tr = g.group(1)
        mt = re.search(r'translate\(\s*(-?[\d.]+)[ ,]+(-?[\d.]+)', tr)
        ms = re.search(r'scale\(\s*(-?[\d.]+)', tr)
        if mt: tx, ty = float(mt.group(1)), float(mt.group(2))
        if ms: sc = float(ms.group(1))
    def bake(p):
        return (round((p[0] + tx) * sc, 2), round((p[1] + ty) * sc, 2))

    best = None
    lo, hi = 0.001, 20.0
    for _ in range(40):  # 二分搜索容差，逼近预算
        mid = (lo + hi) / 2
        cand = [rdp(s, mid) for s in subs]
        n = count_anchors(cand)
        if n > budget:
            lo = mid
        else:
            best = cand; hi = mid
    if best is None:
        best = [rdp(s, 20.0) for s in subs]
    print(f'简化后：{count_anchors(best)} 锚点 / {len(best)} 子路径（预算 {budget}）')

    d = ' '.join(
        'M' + ' L'.join(f'{x} {y}' for x, y in [bake(p) for p in sub])[1:] + ' Z'
        for sub in best
    )
    out = re.sub(r'\sd="[^"]+"', f' d="{d}"', svg, count=1)
    if g:  # 去掉已烘焙的 <g>
        out = out.replace(g.group(0), '<g>', 1)
    open(dst, 'w', encoding='utf-8').write(out)
    print(f'已写出 {dst}（{len(out.encode())} 字节）')


if __name__ == '__main__':
    main()
