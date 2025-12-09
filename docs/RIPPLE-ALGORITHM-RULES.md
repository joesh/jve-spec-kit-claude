Ripple alg rules
1. There are two types of clips: clips and gaps. They both behave the same way. So I’ll call them all items. This way we ONLY deal with items.
2. The border between items is called an EDIT. Each edit has a left and right edge.
3. Each item has a left and right edge.
4. Edges are denoted by [ for left and ] for right.
5. Upstream is the same as left. Downstream is the same as right.
6. Opposing edges are [ and ].
7. If an item has an edge selected and the other edge of the edit ISN’T selected then the action is a RIPPLE. The length of the timeline WILL CHANGE. Dragging the edge changes the size of the item by drag-size. Only the length of the item changes, not its start position.
8. All items that start at or after the edge are shifted in the timeline by drag-size.
9. If both sides of an edit are selected then the action is a ROLL. The length of the timeline WILL NOT CHANGE so this change is local to these edges and bounded by the sizes of the clips. One item will lengthen and the other shrink. No other clips will have to move.
10. Multiple tracks can be involved and each edit may have either a ripple or roll selection.
11. If the edges selected have opposing directions - ie [ and ] - then the delta is negated for the opposing selections.
12. The dragged edge determines the direction of the master delta.

### Alignment with existing NLEs

These rules are not hypothetical—they mirror how professional systems behave today. For reference:

* **Premiere Pro** treats gaps as first-class timeline items. Rolling or rippling a gap boundary behaves exactly like rolling/rippling a clip boundary. (See captured examples dated 2025‑12‑04.)
* **Premiere Pro Ripple Trim** keeps the dragged edge anchored in time when trimming an upstream handle. The clip length changes, downstream material shifts, but the edit point under the cursor does not drift—exactly what Rule 7 specifies.

Future implementations should treat these behaviors as the compatibility bar; any deviation from them will feel broken to editors trained on mainstream NLEs.
