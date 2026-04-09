# Contract: Waveform Renderer (C++ + Lua)

## C++ Layer: TimelineRenderer extension

### New Drawing Command

```cpp
// Add to TimelineRenderer (timeline_renderer.h):
void addWaveform(int x, int y, int width, int height,
                 const float* peaks,   // interleaved [min0, max0, min1, max1, ...]
                 int peak_count,       // number of min/max pairs
                 const QString& color);
```

### New DrawCommand Type

```cpp
struct DrawCommand {
    enum Type { RECT, TEXT, LINE, TRIANGLE, WAVEFORM } type;
    // ... existing fields ...
    // For WAVEFORM:
    std::vector<float> peak_data;  // copied from peaks pointer
    int peak_count;
};
```

### QPainter Execution

In `executeDrawingCommands()`:
```cpp
case DrawCommand::WAVEFORM: {
    painter.setPen(QPen(cmd.color, 1));
    float center_y = cmd.y + cmd.height / 2.0f;
    float half_h = cmd.height / 2.0f;
    float px_per_peak = (float)cmd.width / cmd.peak_count;
    for (int i = 0; i < cmd.peak_count; ++i) {
        float mn = cmd.peak_data[i * 2];
        float mx = cmd.peak_data[i * 2 + 1];
        int px = cmd.x + (int)(i * px_per_peak);
        int y0 = (int)(center_y - mx * half_h);
        int y1 = (int)(center_y - mn * half_h);
        painter.drawLine(px, y0, px, y1);
    }
    break;
}
```

### Lua Binding

```
timeline.add_waveform(widget, x, y, width, height, peak_data_ptr, peak_count, color)
```

- `peak_data_ptr`: lightuserdata from `EMP.PEAK_QUERY()`
- `peak_count`: number of min/max pairs
- Copies float data into DrawCommand (peak_data_ptr may be invalidated after call)

## Lua Layer: timeline_view_renderer.lua

### Integration Point

In `draw_clip_instance()`, after body rect (line 670), before text label (line 677):

```lua
if is_audio and not outline_only and clip_enabled then
    local waveform_enabled = state_module.get_track_waveform_enabled(render_track_id)
    if waveform_enabled ~= false then
        local peaks, count = peak_cache.get_visible_peaks(
            clip.media_id,
            clip.source_in,
            clip.source_out,
            draw_width
        )
        if peaks and count > 0 then
            local wave_color = derive_waveform_color(body_color)
            timeline.add_waveform(view.widget, visible_x, y, draw_width, clip_height, peaks, count, wave_color)
        end
    end
end
```

## Behavior Contract

- `addWaveform` MUST copy peak data from pointer into DrawCommand storage (pointer may be freed after call returns)
- Waveform MUST be centered vertically within the clip rectangle
- Peak values are normalized floats in [-1.0, 1.0] — map to pixel Y relative to center
- If `peak_count` > `width`, subsample peaks (pick max envelope per pixel)
- If `peak_count` < `width`, stretch peaks (repeat or interpolate)
- Waveform MUST render AFTER clip body rect and BEFORE text label (layering order)
- Color derivation: darken body_color by 40% (multiply RGB by 0.6)
