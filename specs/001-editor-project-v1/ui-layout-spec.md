# UI Layout Specification: Video Editor M1 Foundation

## Overall Layout Analysis (DaVinci Resolve Reference)

### Panel Organization
**4-Panel Layout (Clockwise from top-left):**
1. **Media/Project Browser** (Top-Left): ~25% width, ~40% height
2. **Viewer** (Top-Right): ~75% width, ~40% height  
3. **Timeline** (Bottom): ~100% width, ~45% height
4. **Inspector** (Right): ~25% width, ~60% height (overlaps viewer area)

### Panel Proportions
- **Horizontal Split**: ~60% viewer area, ~40% timeline area
- **Vertical Split**: ~75% main content, ~25% browser/inspector panels
- **Dark Theme**: Professional dark gray/black color scheme throughout

## Project Browser Panel (Top-Left)

### Structure
- **Header**: Project name, search/filter controls
- **Folder Tree**: Hierarchical media organization (Footage, Graphics folders)
- **Media List**: File listing with metadata columns
  - Filename, Date Created, Duration, Format
  - Thumbnail previews for video files
- **Smart Bins**: Auto-generated collections

### Key Features
- **Dual-column layout**: Tree view + details
- **Sortable columns**: Click headers to sort by different criteria
- **Search bar**: Real-time filtering of media
- **Context menus**: Right-click operations (import, delete, organize)

## Timeline Panel (Bottom)

### Track Layout
- **Video Tracks**: V1, V2, V3 (top to bottom)
- **Audio Tracks**: A1, A2, A3 (below video tracks)
- **Track Headers**: 
  - Track type indicator (V/A)
  - Track number
  - Enable/disable toggle
  - Lock toggle
  - Track targeting controls

### Timeline Controls
- **Playhead**: Red vertical line with timecode display
- **Zoom Controls**: Timeline scale adjustment
- **Snap Toggle**: Magnetic snapping on/off
- **Tool Selection**: Edit tools (select, blade, slip, etc.)
- **Transport Controls**: Play, stop, frame advance

### Clip Visualization
- **Video Clips**: Blue-toned blocks with thumbnails
- **Audio Clips**: Green-toned blocks with waveforms
- **Clip Labels**: Filename/clip name overlay
- **Transitions**: Diagonal overlaps between clips
- **Selection Highlight**: Bright outline on selected clips

### Ruler & Timecode
- **Top Ruler**: Timecode markers (00:01:00:00 format)
- **Playhead Timecode**: Large display showing current position
- **In/Out Points**: Marked regions for editing operations

## Inspector Panel (Right Side)

### Tab Organization
Based on Resolve Properties panel, structured as:

#### Properties Tab (Video Example)
**Expandable Sections**:
- ✅ **Transform**: Position, scale, rotation controls
- ✅ **Cropping**: Left/Right/Top/Bottom crop values with sliders
- ❌ **Dynamic Zoom**: (collapsed section)
- ✅ **Composite**: Blend modes and opacity
- ✅ **Speed Change**: Playback speed adjustment
- ❌ **Stabilization**: (collapsed section)
- ✅ **Lens Correction**: Distortion adjustments

**Control Types**:
- **Sliders**: Horizontal with numeric input fields
- **Numeric Fields**: Direct value entry (e.g., "0.000")
- **Checkboxes**: Boolean properties
- **Dropdowns**: Enumerated choices
- **Reset Buttons**: Circular arrow icons per property
- **Keyframe Buttons**: Diamond icons for animation

#### Metadata Tab Structure
**Category Chooser** (Right sidebar):
- Shot & Scene
- Clip Details  
- Camera
- Tech Details
- Stereo3D & VFX
- Audio
- Audio Tracks
- Production
- Production Crew
- Reviewed By
- Immersive

**Metadata Fields** (Main area):
- **Shot & Scene Section**: Camera #, Roll Card #, Reel Number, etc.
- **Text Fields**: Program Name, Episode Name, Location
- **Organized Groups**: Related fields clustered logically
- **Form-style Layout**: Label-field pairs in consistent spacing

## Viewer Panel (Top-Right)

### Display Area
- **Video Preview**: Central display area with aspect ratio preservation
- **Safe Areas**: Optional overlay guides for broadcast safe zones
- **Timecode Overlay**: Current position display
- **Transport Controls**: Play/pause/step controls below viewer

### Control Integration
- **Playhead Sync**: Updates in real-time with timeline position
- **Zoom Controls**: Fit/100%/200% view options
- **Overlay Options**: Toggle guides, safe areas, focus assists

## Professional Design Standards

### Color Scheme
- **Background**: Dark charcoal (#2b2b2b)
- **Panel Backgrounds**: Slightly lighter gray (#363636)
- **Text**: Light gray/white (#cccccc)
- **Accents**: Blue for selection (#0078d4)
- **UI Elements**: Medium gray for controls (#555555)

### Typography
- **Monospace**: For timecode and technical values
- **Sans-serif**: For UI labels and controls
- **Consistent Sizing**: Clear hierarchy between headers, labels, values

### Spacing & Layout
- **Consistent Margins**: 8px standard spacing unit
- **Grouped Controls**: Related items visually clustered
- **Aligned Elements**: Grid-based alignment for professional appearance
- **Collapsible Sections**: Expandable groups to manage complexity

### Interaction Patterns
- **Hover States**: Subtle highlighting on interactive elements
- **Selection Feedback**: Clear visual indication of selected items
- **Drag & Drop**: Visual feedback during media placement
- **Context Sensitivity**: Inspector updates based on timeline selection

This detailed layout specification ensures the M1 editor matches professional editor UX expectations while maintaining the specific proportions and organization patterns shown in the reference images.