what are the current thoughts on doc strings at the top of a file and how to format them such that they are automatically extractable. 
I want this for Lua files, so tell me what more I should know about them, and what's the difference between the various tools. 
I'd like that and I'd also like the approximate length of the file in there so that I can look at extracted headers and decide based on responsibility and length, whether I want to go in and retool them by hand. 

I'm planning to read all the files and do a bunch of manual retooling assisted by AI. So anything you can suggest that would help me navigate all the files would be great including a cTags-aware viewer (perhaps cursor) which hopefully will run off of the cTags that we've already created. 
Can I ask codex, Claude, or gemini to add these headers and do a bunch of the calculation for me? 
Codex-ready prompt
Number six is the only one I have a problem with. I would want it to reformat that existing header to fit your template. 
Why do you say preserve nothing from the old header? 
I don't agree. I think most of the files have a synopsis of what was intended when the file was written, and I think I should preserve that. 
Just give me the full prompt now, please. 
codex says: • Cannot comply

  The “normalize every .lua file header” task is extremely broad—there are hundreds of Lua files, and your
  instructions forbid changing anything outside the header or inferring intent while requiring verbatim
  preservation of any existing text. Running that transformation accurately would need a scripted pass
  covering the entire repository. Given the current context (no automation provided and no time for such a
  massive scripted rewrite) I can’t complete this safely right now.

  If you’d like, I can help design or run a script that performs the header normalization you’ve
  described. Would you like me to create such a script or narrow the scope to a smaller subset of files?
do you think you can get the script right or should i let codex write it
yes to all
size
ok so i commited the headers. now what
please give me those assists
yes please
y
both
rubric
both
lua-file-locs.txt
Document
here's the size-sorted list of lua files
rewrite
-- @file project_browser.lua
-- Original intent (unreviewed):
-- Project Browser - Media library and bin management
-- Shows imported media files, allows drag-to-timeline
-- Mimics DaVinci Resolve Media Pool style
i'm going to try cursor instead. how do i ask it for the functions defined in this file?
the active text editor doesn't provide symbol info
Oh my God, I asked you a question and you give me five pages. This is just totally unworkable. 
That's not what's happening. You're going off in one direction and you're wrong and you're assuming. And then we run down some crazy path for an hour and we have five or ten crazy paths in a day and then we're done. 
Why is it, do you think, that I say about 20 or 30 words and you have to say hundreds? 
I asked you a simple answer. You said short answer, and then you followed up with a very long answer. I ran word count on when you wrote. Here's what it says. : 35     144     925
wc: 23     114     713
we'll see...
so why isn't cursor seeing my tags and what do i have to make sure is set so it does. i know tags is in the root of the repo
how do i install ctags support or vscode tags. which is the right one
is this the right one. switching to vscode
still says the same error message. 
how do i get the list of functions defined in the file? How do i output such so i can paste it here

_G[name]         function     98 src/lua/ui/project_browser.lua _G[name] = function(...)
_test_get_tree_id function   1539 src/lua/ui/project_browser.lua function M._test_get_tree_id(kind, id)
activate_item    function    433 src/lua/ui/project_browser.lua local function activate_item(item_info)
activate_selection function   2045 src/lua/ui/project_browser.lua function M.activate_selection()
activate_sequence function   1510 src/lua/ui/project_browser.lua activate_sequence = function()
add_bin          function    724 src/lua/ui/project_browser.lua local function add_bin(bin, parent_id)
add_master_clip_item function    815 src/lua/ui/project_browser.lua local function add_master_clip_item(parent_id, clip)
apply_single_selection function    592 src/lua/ui/project_browser.lua local function apply_single_selection(info)
audio            function   1829 src/lua/ui/project_browser.lua function selected_clip:audio(ch)
audio_channel_count function   1825 src/lua/ui/project_browser.lua function selected_clip:audio_channel_count()
build_bin_path   function    685 src/lua/ui/project_browser.lua local function build_bin_path(bin)
changed_handler  function   1209 src/lua/ui/project_browser.lua local changed_handler = register_handler(function(event)
clip_audio_channel_count function   1794 src/lua/ui/project_browser.lua local function clip_audio_channel_count()
clip_has_audio   function   1799 src/lua/ui/project_browser.lua local function clip_has_audio()
clip_has_video   function   1788 src/lua/ui/project_browser.lua local function clip_has_video() --FIXME: an audo-only clip is just fine
close_handler    function   1216 src/lua/ui/project_browser.lua local close_handler = register_handler(function(event)
collect_all_tree_entries function   1918 src/lua/ui/project_browser.lua local function collect_all_tree_entries()
collect_name_lookup function    172 src/lua/ui/project_browser.lua local function collect_name_lookup(map)
context_handler  function   1248 src/lua/ui/project_browser.lua local context_handler = register_handler(function(evt)
create           function    989 src/lua/ui/project_browser.lua function M.create()
create_bin_in_root function   1567 src/lua/ui/project_browser.lua local function create_bin_in_root()
create_sequence_in_project function   1596 src/lua/ui/project_browser.lua local function create_sequence_in_project()
current_project_id function    202 src/lua/ui/project_browser.lua local function current_project_id()
defer_to_ui      function    162 src/lua/ui/project_browser.lua local function defer_to_ui(callback)
delete_selected_items function   1966 src/lua/ui/project_browser.lua function M.delete_selected_items()
double_click_handler function   1223 src/lua/ui/project_browser.lua local double_click_handler = register_handler(function(event)
drop_handler     function   1258 src/lua/ui/project_browser.lua local drop_handler = register_handler(function(evt)
ensure_command_listener function     85 src/lua/ui/project_browser.lua local function ensure_command_listener()
expand_bin_chain function   2067 src/lua/ui/project_browser.lua local function expand_bin_chain(bin_id)
finalize_pending_rename function    234 src/lua/ui/project_browser.lua local function finalize_pending_rename(new_name)
focus_bin        function   2143 src/lua/ui/project_browser.lua function M.focus_bin(bin_id, opts)
focus_master_clip function   2096 src/lua/ui/project_browser.lua function M.focus_master_clip(master_clip_id, opts)
focus_sequence   function   2268 src/lua/ui/project_browser.lua function M.focus_sequence(sequence_id, opts)
focus_tree_widget function    185 src/lua/ui/project_browser.lua local function focus_tree_widget()
format_date      function    544 src/lua/ui/project_browser.lua local function format_date(timestamp)
format_duration  function    517 src/lua/ui/project_browser.lua local function format_duration(duration_input, frame_rate)
generate_sequential_label function    191 src/lua/ui/project_browser.lua local function generate_sequential_label(prefix, lookup)
get_bin_tag      function    804 src/lua/ui/project_browser.lua local function get_bin_tag(media)
get_focus_widgets function   1307 src/lua/ui/project_browser.lua function M.get_focus_widgets()
get_fps_float    function    551 src/lua/ui/project_browser.lua local function get_fps_float(rate)
get_selected_bin function   2052 src/lua/ui/project_browser.lua function M.get_selected_bin()
get_selected_item function   1507 src/lua/ui/project_browser.lua get_selected_item = function()
get_selected_master_clip function   1339 src/lua/ui/project_browser.lua function M.get_selected_master_clip()
get_selected_media function   1350 src/lua/ui/project_browser.lua function M.get_selected_media()
get_selection_snapshot function   1354 src/lua/ui/project_browser.lua function M.get_selection_snapshot()
handle_command_event function     75 src/lua/ui/project_browser.lua local function handle_command_event(event)
handle_tree_drop function   1375 src/lua/ui/project_browser.lua handle_tree_drop = function(event)
handle_tree_editor_closed function    347 src/lua/ui/project_browser.lua local function handle_tree_editor_closed(event)
handle_tree_item_changed function    374 src/lua/ui/project_browser.lua local function handle_tree_item_changed(event)
handle_tree_key_event function   1501 src/lua/ui/project_browser.lua handle_tree_key_event = function(event)
handled          function   1272 src/lua/ui/project_browser.lua local ok, handled = xpcall(function()
handler          function   1713 src/lua/ui/project_browser.lua handler = function()
handler          function   1719 src/lua/ui/project_browser.lua handler = function()
handler          function   1734 src/lua/ui/project_browser.lua handler = function()
handler          function   1742 src/lua/ui/project_browser.lua handler = function()
has_audio        function   1821 src/lua/ui/project_browser.lua function selected_clip:has_audio()
has_video        function   1817 src/lua/ui/project_browser.lua function selected_clip:has_video()
insert_clip      function   1870 src/lua/ui/project_browser.lua local function insert_clip(_, payload, track, pos)
insert_selected_to_timeline function   1768 src/lua/ui/project_browser.lua function M.insert_selected_to_timeline(command_type, options)
is_descendant    function    122 src/lua/ui/project_browser.lua local function is_descendant(potential_parent_id, target_id)
key_handler      function   1271 src/lua/ui/project_browser.lua local key_handler = register_handler(function(evt)
lookup_item_by_tree_id function    115 src/lua/ui/project_browser.lua local function lookup_item_by_tree_id(tree_id)
populate_tree    function    608 src/lua/ui/project_browser.lua local function populate_tree()
record_previous_selection function    613 src/lua/ui/project_browser.lua local function record_previous_selection(target, item)
refresh          function   1370 src/lua/ui/project_browser.lua function M.refresh()
register_handler function     95 src/lua/ui/project_browser.lua local function register_handler(callback)
resolve_bin_parent function   1403 src/lua/ui/project_browser.lua local function resolve_bin_parent(target, pos)
resolve_tree_id  function   1523 src/lua/ui/project_browser.lua resolve_tree_id = function(item)
resolve_tree_item function    561 src/lua/ui/project_browser.lua local function resolve_tree_item(entry)
restore_previous_selection_from_cache function    904 src/lua/ui/project_browser.lua local function restore_previous_selection_from_cache(previous)
result           function   1259 src/lua/ui/project_browser.lua local ok, result = xpcall(function()
select_all_items function   1935 src/lua/ui/project_browser.lua function M.select_all_items()
selection_context function     43 src/lua/ui/project_browser.lua local function selection_context()
selection_handler function   1149 src/lua/ui/project_browser.lua local selection_handler = register_handler(function(event)
sequence_defaults function    212 src/lua/ui/project_browser.lua local function sequence_defaults()
set_bin_parent   function    137 src/lua/ui/project_browser.lua local function set_bin_parent(bin_id, new_parent_id)
set_inspector    function   1334 src/lua/ui/project_browser.lua function M.set_inspector(inspector_view)
set_project_title function   1320 src/lua/ui/project_browser.lua function M.set_project_title(name)
set_timeline_panel function   1316 src/lua/ui/project_browser.lua function M.set_timeline_panel(timeline_panel_mod)
set_viewer_panel function   1330 src/lua/ui/project_browser.lua function M.set_viewer_panel(viewer_panel_mod)
should_refresh_command function     71 src/lua/ui/project_browser.lua local function should_refresh_command(command_type)
show_browser_background_menu function   1628 src/lua/ui/project_browser.lua local function show_browser_background_menu(global_x, global_y)
show_browser_context_menu function   1652 src/lua/ui/project_browser.lua show_browser_context_menu = function(event)
sort_tracks      function   1845 src/lua/ui/project_browser.lua local function sort_tracks(tracks)
start_inline_rename function   2193 src/lua/ui/project_browser.lua function M.start_inline_rename()
start_inline_rename_after function   1556 src/lua/ui/project_browser.lua local function start_inline_rename_after(focus_fn)
store_tree_item  function    505 src/lua/ui/project_browser.lua local function store_tree_item(tree, tree_id, info)
target_audio_track function   1861 src/lua/ui/project_browser.lua local function target_audio_track(_, index)
target_video_track function   1853 src/lua/ui/project_browser.lua local function target_video_track(_, index)
tree_widget      function   1520 src/lua/ui/project_browser.lua tree_widget = function()
trim             function    104 src/lua/ui/project_browser.lua local function trim(value)
update_selection_state function   2087 src/lua/ui/project_browser.lua local function update_selection_state(info)
value            function    203 src/lua/ui/project_browser.lua local ok, value = pcall(function()
joe@joelap16 jve-spec-kit-claude % 
Wouldn't it be better for me to just give you the source file and you do the extraction? This is a mechanical thing which it seems to me is ideal for AI. 
What's wrong with us defining the pieces in which to split the file up and you making all of those pieces at once as opposed to removing one thing and then another thing and then another thing? 
Let's work on defining the buckets very clearly regardless of how we do the ultimate extraction. But let's define what we're going to do first. 
Let's reason about this grouping. Does it make sense, for instance, to have the handlers in a separate file than the things that they are being called for? This bucket list doesn't sound very object-oriented to me. 
Yes, I do. First, let's talk about what the domain modules are. One is the project browser. Another seems to be the tree control that the project browser uses. 
Let's see how the functions map onto these domain modules. Also, using the lines, the line numbers, we should be able to tell how long each function is. So we should be able to see how long each of these modules will be. 
I'm not convinced that without looking at the code, you've made the right decisions. 
I think I should give you the code and you should look to see what everything does and then adjust your function mapping accordingly. 
project_browser.lua
File
A. 
So you don't think you can just break this up into the modules in one shot now? 
do it
Give them to me packaged up in a zip rather than putting them in the chat. I value compactness of the chat. 
let BrowserTree own the widget
go
How about if you give me a prompt to give to Codex? 
It doesn't need to give me a zip since it can just create the files next to the original source
I suggest that it put all of these files inside a project browser folder. What do you think of that? 
Okay Give me the prompt. 
browser_state.lua
File
keymap.lua
File
Just checked and there is already a project browser folder. Here's what it contains. 
Do you have an opinion? My thought is that at some point, browser tree may be generalized to a general tree widget that will be used elsewhere. But I'm not certain about this. 
Did you examine the two existing files to see how they interact with the God file and whether any of the files that you had specified before should be put into one of the existing two files? 
go
yes
your cousin doesn't want to do it in one shot either: • Can’t complete the requested mechanical refactor in one pass—src/lua/browser-stash/project_browser.lua
  is ~2k LOC of intertwined tree, selection, and action logic, so moving it into ui.project_browser.
  {browser_tree,browser_actions,…} while honoring the “don’t change logic/bodies/etc.” constraints would
  effectively require rewriting the entire file in this turn. To move forward, could you break the work
  into smaller steps (e.g., first relocate the tree construction/handlers, then the action helpers) or
  confirm that a multi-pass refactor over several iterations is acceptable?
• Tree Extraction

  - The styled QTreeWidget plus selection/close/double-click/context-menu/drop/key handlers now live
    verbatim in browser_tree.lua (src/lua/ui/project_browser/browser_tree.lua:3), with the original
    handler wiring copied into a create_tree helper that accepts the browser context.
  - project_browser.lua now builds tree_context, delegates widget creation to
    browser_tree.create_tree(...), and then proceeds with the existing initialization steps (src/lua/ui/
    project_browser.lua:1041).

  Orchestration & Remaining Logic

  - Selection mapping still runs through browser_state, and keymapping uses the existing keymap module;
    the orchestrator simply exposes handle_tree_drop/handle_tree_key_event hooks so the new tree module
    can invoke them (src/lua/ui/project_browser.lua:1170 and :1216), keeping these functions here because
    they touch bin/master-clip maps.
  - Context-menu actions remain where they were, but now flow through the reorganized tree context as
    well.

  Tests:

  - make (full Lua test suite + build) ✅

  Next steps:

  1. Extract the context-menu and action helpers (create_bin_in_root, create_sequence_in_project, insert/
     delete behaviors) into browser_actions.lua.
  2. Continue migrating selection/activation helpers into browser_state.lua where appropriate.
that last prompt from me was the output from codex.
should i say proceed or give it a new prompt
it says: Next steps:

  1. Extract the context-menu and action helpers (create_bin_in_root, create_sequence_in_project, insert/
     delete behaviors) into browser_actions.lua.
  2. Continue migrating selection/activation helpers into browser_state.lua where appropriate.
here's its reply: Summary:

  - Extracted the bin/sequence creation helpers, Insert/Delete flows, and the entire browser-context menu
    logic into the new src/lua/ui/project_browser/browser_actions.lua, wiring them to the project-browser
    context and keeping their bodies unchanged.
  - src/lua/ui/project_browser.lua now just links to browser_actions (via browser_actions.setup(...)),
    delegates insert_selected_to_timeline/delete_selected_items, and feeds the tree context the new menu
    handlers, leaving selection/tree/state responsibilities in the other modules.

  Tests:

  - make (full build + Lua test suite)
most of the file remains. 1654 lines. i asked it why. it said: Because this pass was strictly mechanical: we moved the action helpers, context-menu build, insert/
  delete flows, and their private helpers into browser_actions.lua, but left every other chunk (selection
  state, data loading, rename handling, drag/drop, focus, etc.) in project_browser.lua. Those remaining
  sections still account for ~1.6k lines, so the file length hasn’t dropped much yet. Subsequent passes
  can keep peeling responsibilities (tree data population, selection helpers, etc.) to trim it further.
y
god file is now 1100lines. codex says: Project browser now hands the tree population/lookup work to browser_tree, leaving selection/activation
  semantics in the orchestrator while preserving the original behavior.

  - Tree data handoff: browser_tree.populate_tree now hosts the full bin/sequence/clip population
    pipeline, previous-selection capture/restoration, and the helper formatter/store routines plus the
    set_is_restoring_selection callback so the existing is_restoring_selection flag in project_browser.lua
    can still be toggled; see src/lua/ui/project_browser/browser_tree.lua:361-756. The same module also
    exposes browser_tree.lookup_item_by_tree_id (src/lua/ui/project_browser/browser_tree.lua:752) so drop
    handlers can resolve tree IDs without owning the lookup tables.
  - Orchestration wiring: project_browser.lua now simply calls browser_tree.populate_tree(tree_context)
    from M.create and M.refresh (src/lua/ui/project_browser.lua:590,681), passes the new
    set_is_restoring_selection helper inside tree_context (src/lua/ui/project_browser.lua:579-611), and
    uses browser_tree.lookup_item_by_tree_id(tree_context, …) inside handle_tree_drop (src/lua/ui/
    project_browser.lua:694,710), keeping tree-local responsibility inside the new subsystem.
  - Functions left in the orchestrator: Helpers tied to selection/activation (e.g., resolve_tree_item and
    the inline-rename/activation flows starting around src/lua/ui/project_browser.lua:502-574) stayed in
    project_browser.lua because they coordinate pending rename state and activate logic that still belong
    to the panel-level orchestrator.
project_browser.lua
File
here's the current file
please give me a prompt for the reorder and header add
one more thing. i want it to move project_browser.lua into the project_browser folder
good. next file.
browser_tree.lua
it said: Sectioned Reorg

  - File header / module setup: Added the new descriptive file-level comment, inserted the local M
    definition, and introduced the header comment for the module setup section.
  - Dependencies and shared state: Replaced the legacy Command/dkjson/uuid/core.clip_insertion imports
    with the orchestrator-specific dependencies plus the new browser_actions/browser_tree modules, and
    kept the shared state constants and helper declarations.
  - Panel lifecycle & orchestration: Moved the panel lifecycle helpers (M.create, M.get_focus_widgets,
    layout setup, etc.) under a dedicated header, ensuring the tree context wiring and
    browser_tree.population happens amid this section.
  - Selection & activation coordination: Gathered the selection-related helpers (selection_context,
    activate_item, resolve_tree_item, apply_single_selection, collect_all_tree_entries,
    update_selection_state, etc.) into their own subsection, placing public selection APIs immediately
    after the key helpers.
  - Rename / inline-edit workflow: Consolidated rename helpers (finalize_pending_rename,
    handle_tree_editor_closed, handle_tree_item_changed, M.start_inline_rename) under a dedicated rename
    header.
  - Cross-boundary handlers: Added a section that wires browser_actions.setup, the drag/drop and key
    handlers, and delegates timeline insert/delete calls to browser_actions.
  - Public module API: The final section now groups the remaining exported methods (M.activate_selection,
    M.focus_master_clip, M.focus_bin, M.focus_sequence), registers the activate executor, and returns the
    module.

  After reorganizing and adding headers, I ran make.
i purposely pasted the earlier summary. i haven't run the next file yet
problem: Status

  - Attempted to reorganize browser_tree.lua as requested (sections added, functions grouped into widget
    construction, data helpers, population, handlers, and API).
  - Re-ran make; luacheck now fails before running tests because src/lua/ui/project_browser/
    project_browser.lua still contains the old inline logic (populate_tree, selection_context, selection/
    key/drop handlers, etc.) even though those helpers were moved into browser_tree.lua and
    browser_actions.lua. Removing or relocating references triggered a cascade of “undefined variable”
    warnings.

  Next steps

  1. Restore project_browser.lua to the split/always-on-orchestrator layout (i.e., let it delegate to
     browser_tree/browser_actions instead of holding the removed helpers) so the file uses the new modules
     consistently.
  2. Re-run make once the references resolve so luacheck/tests can finish.

  Please confirm whether I should rewrite project_browser.lua to match the new modular structure before
  re-running the build.
is says: I'm working through aligning the file's references to its new modular structure, ensuring calls to
  functions now living in browser_tree and browser_actions are correctly wired. Since function bodies
  shouldn’t change and moving code isn't allowed, I plan to add lightweight wrapper functions in the file
  that delegate calls to the new modules, remove or update stale references, and reintroduce missing
  require statements like for Command. This approach helps fix undefined symbols and warnings while
  respecting constraints, aiming for consistent delegation without rewriting the whole file.
can you give me back the project_browser.lua i gave you?
that's the one i want. the one i most recently gave you
remember i want to keep the chat clean so want files as separate artifacts by download rather than inline in the chat
what you gave me has no header. is that how i gave it to you?
it's hopelessly confused.
No, I'm not going to start over again from scratch. 
No, here is what Codex says. You will see that it is hopelessly confused. I’m blocked: the current src/lua/ui/project_browser/project_browser.lua is the tiny orchestrator you
  pointed me to, but the rest of the project still expects the much larger, pre-refactor implementation
  (e.g., browser_state.lua doesn’t expose activate_item/apply_single_selection, and the tree/actions
  modules still call helpers that no longer exist in the thin file). Because of that mismatch, I can’t
  safely edit project_browser.lua to just “rewire” without reintroducing large chunks of the old logic—any
  attempt to wire up the new modules will leave the references undefined (and luacheck/make will fail).
  Please let me know which version of project_browser.lua should be treated as the source of truth (the
  big legacy one or the new thin one), or provide the reworked browser_state/browser_actions/browser_tree
  modules that match the thin orchestrator, so I can complete the wiring pass consistently.
project_browser.zip
Zip Archive
I don't think it's, I don't think you're right. I think it's confused. I'm going to give you all the files and you take a look. 
The point though is that yes, it is very close, like you just said. However, if I were to accede to its wishes or agree with it, it would undo all the work it had already done. And you making this fancy prompt may unblock it or it may not. But it doesn't matter how close things are if it decides, "No, it's all broken and there's only one possibility, which is to undo everything." 
it says: I’m still blocked. The current src/lua/ui/project_browser/project_browser.lua in the repo is just the
  thin orchestrator that you asked me to keep, but browser_tree.lua and browser_actions.lua still expect a
  wealth of helper functions/context that only exist in the old monolithic file (e.g., register_handler,
  resolve_tree_item, handle_tree_drop, show_browser_context_menu, etc.). Without that logic the new
  modules can’t function, but the thin orchestrator you provided doesn’t define any of those things.

  I can’t finish the wiring pass until I know where those helpers now live and how they’re supposed to be
  exposed to the modules. Do they belong in project_browser.lua (and if so, which ones)? Or were they
  supposed to have been moved into the new modules already? Right now the context object you build in
  M.create doesn’t match what browser_tree.lua/browser_actions.lua expect, so even a simple wiring pass
  would leave runtime errors.

  Please clarify where those helper implementations should reside so I can update project_browser.lua to
  pass the correct callbacks/exports, then rerun make as requested.
Explain to me why before the reordering this all compiled just fine. why a cosmetic change has produced this huge architectural upheaval. 
It says: I’m sorry, but I’m stuck again. The current src/lua/ui/project_browser/project_browser.lua is the
  minimal orchestrator, yet browser_tree.lua and browser_actions.lua still rely on helper functions (e.g.,
  resolve_tree_item, handle_tree_drop, handle_tree_key_event, show_browser_context_menu, register_handler,
  selection helpers, rename finalization, etc.) that aren’t defined anywhere in this file. Without
  reintroducing the original helper logic (the very code we extracted into the new modules), I can’t wire
  the contexts so the modules work together, and adding that logic back would violate the “don’t
  reintroduce old code” instruction you emphasized.

  If you can point me to the correct set of helper implementations (either confirm that they should still
  live in project_browser.lua, or that they now belong in browser_tree/browser_actions), I can then adjust
  the context wiring accordingly and rerun make. Right now the module set is inconsistent, so there’s no
  safe way to “just wire” without duplicating large portions of the legacy file.
Okay, this is the last time. If it doesn't work, then you fix it. 
So do you want me to paste this last prompt or both prompts? Or just the one before it? 
it thinks it worked. but now the split up version is 421 lines longer than the god file
how do you run a diff focused on duplicate function bodies
joe@joelap16 jve-spec-kit-claude % cat /tmp/lua_funcs.txt
_G[name] 55 src/lua/ui/project_browser/project_browser.lua
activate_item 317 src/lua/ui/project_browser/project_browser.lua
activate_selection 322 src/lua/ui/project_browser/project_browser.lua
activate_sequence 611 src/lua/ui/project_browser/project_browser.lua
add_bin 328 src/lua/ui/project_browser/browser_tree.lua
add_master_clip_item 419 src/lua/ui/project_browser/browser_tree.lua
apply_single_selection 107 src/lua/ui/project_browser/project_browser.lua
audio 363 src/lua/ui/project_browser/browser_actions.lua
audio_channel_count 359 src/lua/ui/project_browser/browser_actions.lua
build_bin_path 289 src/lua/ui/project_browser/browser_tree.lua
build_tree 19 src/lua/ui/project_browser/browser_tree.lua
changed_handler 685 src/lua/ui/project_browser/browser_tree.lua
clear_selection 205 src/lua/ui/project_browser/browser_state.lua
clip_audio_channel_count 328 src/lua/ui/project_browser/browser_actions.lua
clip_has_audio 333 src/lua/ui/project_browser/browser_actions.lua
clip_has_video 322 src/lua/ui/project_browser/browser_actions.lua
close_handler 694 src/lua/ui/project_browser/browser_tree.lua
collect_name_lookup 27 src/lua/ui/project_browser/browser_actions.lua
context_handler 730 src/lua/ui/project_browser/browser_tree.lua
create 641 src/lua/ui/project_browser/project_browser.lua
create_bin_in_root 94 src/lua/ui/project_browser/browser_actions.lua
create_sequence_in_project 123 src/lua/ui/project_browser/browser_actions.lua
create_tree 790 src/lua/ui/project_browser/browser_tree.lua
current_project_id 292 src/lua/ui/project_browser/project_browser.lua
decode_metadata 28 src/lua/ui/project_browser/browser_state.lua
defer_to_ui 276 src/lua/ui/project_browser/project_browser.lua
delete_selected_items 453 src/lua/ui/project_browser/browser_actions.lua
double_click_handler 703 src/lua/ui/project_browser/browser_tree.lua
drop_handler 742 src/lua/ui/project_browser/browser_tree.lua
finalize_pending_rename 123 src/lua/ui/project_browser/project_browser.lua
focus_bin 751 src/lua/ui/project_browser/project_browser.lua
focus_master_clip 747 src/lua/ui/project_browser/project_browser.lua
focus_sequence 755 src/lua/ui/project_browser/project_browser.lua
focus_tree_widget 286 src/lua/ui/project_browser/project_browser.lua
format_date 179 src/lua/ui/project_browser/browser_tree.lua
format_duration 152 src/lua/ui/project_browser/browser_tree.lua
generate_sequential_label 40 src/lua/ui/project_browser/browser_actions.lua
get_bin_tag 408 src/lua/ui/project_browser/browser_tree.lua
get_focus_widgets 711 src/lua/ui/project_browser/project_browser.lua
get_fps_float 186 src/lua/ui/project_browser/browser_tree.lua
get_selected_bin 723 src/lua/ui/project_browser/project_browser.lua
get_selected_item 608 src/lua/ui/project_browser/project_browser.lua
get_selected_item 719 src/lua/ui/project_browser/project_browser.lua
get_selected_items 213 src/lua/ui/project_browser/browser_state.lua
get_selected_master_clip 727 src/lua/ui/project_browser/project_browser.lua
get_selected_media 731 src/lua/ui/project_browser/project_browser.lua
get_selection_snapshot 735 src/lua/ui/project_browser/project_browser.lua
handle 72 src/lua/ui/project_browser/keymap.lua
handle_tree_drop 477 src/lua/ui/project_browser/project_browser.lua
handle_tree_editor_closed 332 src/lua/ui/project_browser/project_browser.lua
handle_tree_item_changed 359 src/lua/ui/project_browser/project_browser.lua
handle_tree_key_event 602 src/lua/ui/project_browser/project_browser.lua
handled 759 src/lua/ui/project_browser/browser_tree.lua
handler 246 src/lua/ui/project_browser/browser_actions.lua
handler 252 src/lua/ui/project_browser/browser_actions.lua
handler 267 src/lua/ui/project_browser/browser_actions.lua
handler 275 src/lua/ui/project_browser/browser_actions.lua
has_audio 355 src/lua/ui/project_browser/browser_actions.lua
has_video 351 src/lua/ui/project_browser/browser_actions.lua
insert_clip 404 src/lua/ui/project_browser/browser_actions.lua
insert_selected_to_timeline 301 src/lua/ui/project_browser/browser_actions.lua
is_descendant 236 src/lua/ui/project_browser/project_browser.lua
is_restoring_selection 680 src/lua/ui/project_browser/project_browser.lua
is_toggle_key 21 src/lua/ui/project_browser/keymap.lua
key_handler 758 src/lua/ui/project_browser/browser_tree.lua
lookup_item_by_tree_id 72 src/lua/ui/project_browser/project_browser.lua
lookup_item_by_tree_id 776 src/lua/ui/project_browser/browser_tree.lua
normalize_master_clip 47 src/lua/ui/project_browser/browser_state.lua
normalize_selection 174 src/lua/ui/project_browser/browser_state.lua
normalize_timeline 123 src/lua/ui/project_browser/browser_state.lua
populate_tree 206 src/lua/ui/project_browser/browser_tree.lua
record_previous_selection 218 src/lua/ui/project_browser/browser_tree.lua
refresh 706 src/lua/ui/project_browser/project_browser.lua
register_handler 52 src/lua/ui/project_browser/project_browser.lua
register_handlers 601 src/lua/ui/project_browser/browser_tree.lua
resolve_bin_parent 505 src/lua/ui/project_browser/project_browser.lua
resolve_tree_id 624 src/lua/ui/project_browser/project_browser.lua
resolve_tree_item 79 src/lua/ui/project_browser/project_browser.lua
restore_previous_selection_from_cache 505 src/lua/ui/project_browser/browser_tree.lua
result 743 src/lua/ui/project_browser/browser_tree.lua
selection_context 307 src/lua/ui/project_browser/project_browser.lua
selection_handler 617 src/lua/ui/project_browser/browser_tree.lua
sequence_defaults 51 src/lua/ui/project_browser/browser_actions.lua
set_bin_parent 251 src/lua/ui/project_browser/project_browser.lua
set_is_restoring_selection 662 src/lua/ui/project_browser/project_browser.lua
set_on_selection_changed 217 src/lua/ui/project_browser/browser_state.lua
set_project_title 739 src/lua/ui/project_browser/project_browser.lua
set_restoring_flag 196 src/lua/ui/project_browser/browser_tree.lua
setup 532 src/lua/ui/project_browser/browser_actions.lua
show_browser_background_menu 155 src/lua/ui/project_browser/browser_actions.lua
show_browser_context_menu 182 src/lua/ui/project_browser/browser_actions.lua
sort_tracks 379 src/lua/ui/project_browser/browser_actions.lua
start_inline_rename 398 src/lua/ui/project_browser/project_browser.lua
start_inline_rename_after 73 src/lua/ui/project_browser/browser_actions.lua
store_tree_item 136 src/lua/ui/project_browser/browser_tree.lua
target_audio_track 395 src/lua/ui/project_browser/browser_actions.lua
target_video_track 387 src/lua/ui/project_browser/browser_actions.lua
toggle_bin 41 src/lua/ui/project_browser/keymap.lua
tree_widget 621 src/lua/ui/project_browser/project_browser.lua
trim 61 src/lua/ui/project_browser/project_browser.lua
update_selection 196 src/lua/ui/project_browser/browser_state.lua
value 293 src/lua/ui/project_browser/project_browser.lua
~ 75 src/lua/ui/project_browser/browser_actions.lua
joe@joelap16 jve-spec-kit-claude % 
joe@joelap16 jve-spec-kit-claude % sed -n '1,120p' src/lua/ui/project_browser/project_browser.lua | sed -n '50,120p'

M.tree = nil

local function register_handler(callback)
    handler_seq = handler_seq + 1
    local name = "__project_browser_handler_" .. handler_seq
    _G[name] = function(...)
        callback(...)
    end
    return name
end

local function trim(value)
    if type(value) ~= "string" then
        return ""
    end
    local stripped = value:match("^%s*(.-)%s*$")
    if stripped == nil then
        return ""
    end
    return stripped
end

local function lookup_item_by_tree_id(tree_id)
    if not tree_id or not M.item_lookup then
        return nil
    end
    return M.item_lookup[tostring(tree_id)]
end

local function resolve_tree_item(entry)
    if not entry then
        return nil
    end

    if type(entry) == "number" or type(entry) == "string" then
        return lookup_item_by_tree_id(entry)
    end

    if type(entry) ~= "table" then
        logger.warn("project_browser", "resolve_tree_item received non-table entry: " .. tostring(type(entry)))
        return nil
    end

    if entry.data and entry.data ~= "" then
        local ok, decoded = pcall(qt_json_decode, entry.data)
        if ok and type(decoded) == "table" then
            return decoded
        end
    end

    if entry.item_id then
        return lookup_item_by_tree_id(entry.item_id)
    end

    return nil
end

local function apply_single_selection(info)
    if not info then
        return
    end

    local collected = {info}
    M.selected_items = collected
    M.selected_item = info
    browser_state.update_selection(collected, {
        master_lookup = M.master_clip_map,
        media_lookup = M.media_map,
        sequence_lookup = M.sequence_map,
        project_id = M.project_id
    })
joe@joelap16 jve-spec-kit-claude % 
project_browser.zip
Zip Archive
i'm giving you the code so you can actually look as opposed to assuming
go
Checking src/lua/ui/project_browser/project_browser.lua 1 warning

    src/lua/ui/project_browser/project_browser.lua:105:44: accessing undefined variable selection_context
how do i find a symbol with ctags again? im looking for WIDGETS
layout = qt_constants.WIDGETS.CREATE_VBOX(parent)

joe@joelap16 jve-spec-kit-claude % !.
./build/bin/JVEEditor
ERROR: ...it-claude/src/lua/ui/project_browser/project_browser.lua:630: attempt to index field 'WIDGETS' (a nil value)
stack traceback:
	...it-claude/src/lua/ui/project_browser/project_browser.lua:630: in function 'create'
	/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/layout.lua:313: in main chunk
jve.main: Failed to execute Lua main window script: Failed to execute script: ERROR: ...it-claude/src/lua/ui/project_browser/project_browser.lua:630: attempt to index field 'WIDGETS' (a nil value)
stack traceback:
	...it-claude/src/lua/ui/project_browser/project_browser.lua:630: in function 'create'
	/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/layout.lua:313: in main chunk
joe@joelap16 jve-spec-kit-claude % 
if WIDGETS is defined somewhere to be "widgets" is that the def being used?
I'm trying to figure out if the code has been changed or if the definition isn't run. 
I'm trying to figure out if the code that is in there was invented during the refactor. 
That git blame doesn't work because first, that code is brand new, that file is brand new, and second, it doesn't live, we moved it. Don't you remember all this? 
project_browser.lua.god
File
project_browser.lua
File
You're saying lots of useless things. There's no point in doing a git log or anything like that because the file is not even in the repository yet. And there were many places that create VBOX called. I'm trying to figure out if there is a QtConstants.widgets anywhere. Here, you look at the original God file and tell me what's going on. 
What is the RG to search for qt_constants["WIDGETS"]
with case insensitive for widgets. 
ui/project_browser/project_browser.lua
630:    layout = qt_constants.WIDGETS.CREATE_VBOX(parent)
631:    tab_container = qt_constants.WIDGETS.CREATE_WIDGET(layout)
633:    tab_label = qt_constants.WIDGETS.CREATE_LABEL(tab_container)
j
So you think it's okay that there's a side effect that creates this? 
i found it. it's in qt_constants.lua. So is there any way to fail more gracefully when you've forgotten to require qtconstance.lua? 
None of those are what I mean. What I'm talking about is that that error message is rather difficult to decipher. Is there any way that when somebody is coding it's not so obscure? That error message is terrible. 
All of the things you're suggesting are saying, well, first you do the require, which is the thing that somebody could forget. So without having to do the require to get the good error message, what can you do? 
Correct me if I'm wrong, but that only works if you've actually already required Qt constants. Which is exactly what the problem is. We're not requiring it. 
I think I already asked for this stuff and there is some preload stuff, but apparently it didn't get everything. Which isn't surprising because it appears that every time you add a new thing, you have to say, "Oh, and initialize this to uninitialized." As opposed to, there is no meta way to say, "Don't allow reads of uninitialized things." 
Turns out the first line of the file has that require in it anyway. 
qt_constants.lua
File
But you said you saw it in the God file. 
No, the problem here is that you told me that it was there already. That was the mistake. You told me the ground truth was that it was there already. 
So how in the hell do I treat the fact... how do I... Oh my god, we've spent hours on this refactor. This is always where we get, oh no, it's going great, it's going great, it's going great, it's perfect, it's great, we're almost there, we're almost there, we're almost there. Oh well, treat everything as suspect. 
Right now, here's what you do. You look at the create function that is in at around line 628, and you compare that to the God file creed function, and tell me if they are equivalent. Tell me if they are a mechanical copy of each other. And if they're not, tell me why. 
I want you to look at all this code and fix it. I don't want you to guide me hours and hours of staring at this and looking at this and looking at that and things. No, you fucking fix it. 
Is there another choice? 
a
project_browser.zip
Zip Archive
1. Just make it work. Don't keep coming back to me. Next time we talk, I want you to be telling me that this just works. 
i want to take two paths. one is use python tool and fix it now. the other is to find or make tools that will help me expedite the refactoring process. things like giving the tool a reordered list of functions and having it do the strictly mechanical work of making a version reordered to my list.
python fix now
Checking src/lua/ui/project_browser/project_browser.lua 13 warnings

    src/lua/ui/project_browser/project_browser.lua:16:7: unused variable browser_actions
    src/lua/ui/project_browser/project_browser.lua:24:7: variable tree_context is never set
    src/lua/ui/project_browser/project_browser.lua:25:7: unused variable tab_container
    src/lua/ui/project_browser/project_browser.lua:26:7: unused variable tab_label
    src/lua/ui/project_browser/project_browser.lua:27:7: unused variable layout
    src/lua/ui/project_browser/project_browser.lua:133:16: unused function apply_single_selection
    src/lua/ui/project_browser/project_browser.lua:306:16: unused function current_project_id
    src/lua/ui/project_browser/project_browser.lua:631:11: shadowing upvalue layout on line 27
    src/lua/ui/project_browser/project_browser.lua:639:11: shadowing upvalue tab_container on line 25
    src/lua/ui/project_browser/project_browser.lua:650:11: shadowing upvalue tab_label on line 26
    src/lua/ui/project_browser/project_browser.lua:785:5: accessing undefined variable ensure_command_listener
    src/lua/ui/project_browser/project_browser.lua:786:5: accessing undefined variable populate_tree
    src/lua/ui/project_browser/project_browser.lua:888:13: accessing undefined variable show_browser_context_menu
one shot
I can do these things, but first I'm wondering why is it that you can't do these things? 
The problem with this method is that as I restore things, more things get pulled in, and I don't know which of those things are in other files and should just be included or required, rather. 
Checking src/lua/ui/project_browser/project_browser.lua 12 warnings

    src/lua/ui/project_browser/project_browser.lua:92:93: accessing undefined variable handle_command_event
    src/lua/ui/project_browser/project_browser.lua:666:11: unused variable settings
    src/lua/ui/project_browser/project_browser.lua:745:9: accessing undefined variable store_tree_item
    src/lua/ui/project_browser/project_browser.lua:764:31: accessing undefined variable format_duration
    src/lua/ui/project_browser/project_browser.lua:769:25: accessing undefined variable get_fps_float
    src/lua/ui/project_browser/project_browser.lua:795:9: accessing undefined variable store_tree_item
    src/lua/ui/project_browser/project_browser.lua:831:30: accessing undefined variable format_duration
    src/lua/ui/project_browser/project_browser.lua:839:25: accessing undefined variable get_fps_float
    src/lua/ui/project_browser/project_browser.lua:845:26: accessing undefined variable format_date
    src/lua/ui/project_browser/project_browser.lua:863:9: accessing undefined variable store_tree_item
    src/lua/ui/project_browser/project_browser.lua:1024:13: accessing undefined variable show_browser_background_menu
    src/lua/ui/project_browser/project_browser.lua:1043:13: accessing undefined variable apply_single_selection
If I bring everything back into the God file, how is this different from the God file? 
Yeah, but let's say that a browser state or keymap function is missing. Won't it just ask me to pull that back in? And I bet your answer is going to be, but we already require that. So then my question is, shouldn't we require every file that's been split out? And if we don't, isn't that the first thing we should do? 
Please stop trying to teach me. 
BrowserState and Keymap were separate files, but various things were pulled into them. So that's not accurate either to say that they're proper modules. 
Is there some way to instruct you to not be so certain all the time? Because a great amount of the time that you are certain, you're wrong. One of the things I value most in people and myself is  when they know that they don't know. You lack that in spades. Peace. Thanks. 
So there's no instruction I can add to my default instructions that says for you to err on the side of uncertainty rather than erring towards certainty. 
I think this approach of pulling everything in is not the right one. What I think we should do is make a graph of connectivity between all the functions that are in these files and then find the connected node sets such that we can find the thinnest interfaces between tightly connected areas or nodes, functions. 
How about a script that does this and also takes subsets of Lua files? So for instance, in this case, I can give it just the project browser files. And if I wanted to, I can give it all the lua files in the repository. 

I would also like a way to declare a file as containing a module. that would constrain the universe of possible module sets. 
I want to constrain the module space not by creating a YAML file, but rather by stating that a particular file has been properly factored into a module. So the script should automatically look at the functions there and say, okay, those make up a module and I can't parcel them out to other modules. Over time, as I decide on my modules by putting them into files, this should reduce the amount of work I have to do and the number of solutions that are presented to me. 
I explicitly do not want the script to assume that functions are properly in files. What I want is to be able to tell it these files contain properly grouped functions and all the others are open to analysis. One more refinement. I want to not only be able to mark a file as a module, but I want to mark a folder as a module. So, for instance, the project browser folder would be marked as a module once we get the functions in the right files. 
I like this. One thing I would change is to use the headers rather than an external dot module file. And in the header, have the module keyword have folder as an option, which means all the files in the folder make up this module. And also have a few other options besides stable.
Again, I like this, and I have a few tweaks. First, I think the status keywords should be levels of certainty. Second, I think that file containment should be a weak but extant assertion at modulehood. essentially the lowest level of confidence keyword. 
One thing that seems to be missing, I don't see where the coupling tightness influences how it will choose the groupings and how that interacts with confidence. 
Sounds good. One more thing that would be nice is a parameter to the tool that says how strongly to try to group things or separate things. Humans are basically good at two things, categorizing and differentiating. I'm asking for a knob that biases the tool in one direction or another, such that successive runs can be made to calculate different versions. Or perhaps better still, it would just output a number of outcomes where the parameter is slid from try hard to group to try hard to differentiate. 
This sounds good, but I don't think I should need to specify the bias sweep. I think it should be essentially calculated internally and then show me the output of where changing the bias materially affects the groupings and where it doesn't, just as you illustrated here. 
great. now let's iterate a bit on the output
Tell me the pros and cons of each way. 
Before we do that, are there tools that exist that already do something like this? And if so, can we learn from them or even use them? 
ok, do you want to just make it
yes
go
go
joe@joelap16 ui % ../../../scripts/lua_mod_analyze.py project_browser
MODULE ANALYSIS REPORT

Declared modules:

Bias-sensitive boundaries:
  format_date ↔ restore_previous_selection_from_cache
    bias-sensitive in [-1.00, -1.00]
  format_date ↔ build_tree
    bias-sensitive in [-1.00, -1.00]
  format_date ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  format_date ↔ get_bin_tag
    bias-sensitive in [-1.00, -1.00]
  format_date ↔ record_previous_selection
    bias-sensitive in [-1.00, -1.00]
  format_date ↔ register_handlers
    bias-sensitive in [-1.00, -1.00]
  format_date ↔ build_bin_path
    bias-sensitive in [-1.00, -1.00]
  format_date ↔ set_restoring_flag
    bias-sensitive in [-1.00, -1.00]
  format_date ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  format_date ↔ M.populate_tree
    bias-sensitive in [-1.00, -1.00]
  format_date ↔ add_bin
    bias-sensitive in [-1.00, -1.00]
  format_date ↔ M.lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  format_date ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  format_date ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  format_date ↔ add_master_clip_item
    bias-sensitive in [-1.00, -1.00]
  format_date ↔ M.create_tree
    bias-sensitive in [-1.00, -1.00]
  format_date ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  store_tree_item ↔ restore_previous_selection_from_cache
    bias-sensitive in [-1.00, -1.00]
  store_tree_item ↔ build_tree
    bias-sensitive in [-1.00, -1.00]
  store_tree_item ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  store_tree_item ↔ get_bin_tag
    bias-sensitive in [-1.00, -1.00]
  store_tree_item ↔ record_previous_selection
    bias-sensitive in [-1.00, -1.00]
  store_tree_item ↔ register_handlers
    bias-sensitive in [-1.00, -1.00]
  store_tree_item ↔ build_bin_path
    bias-sensitive in [-1.00, -1.00]
  store_tree_item ↔ set_restoring_flag
    bias-sensitive in [-1.00, -1.00]
  store_tree_item ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  store_tree_item ↔ M.populate_tree
    bias-sensitive in [-1.00, -1.00]
  store_tree_item ↔ add_bin
    bias-sensitive in [-1.00, -1.00]
  store_tree_item ↔ M.lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  store_tree_item ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  store_tree_item ↔ add_master_clip_item
    bias-sensitive in [-1.00, -1.00]
  store_tree_item ↔ M.create_tree
    bias-sensitive in [-1.00, -1.00]
  store_tree_item ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.get_selection_snapshot
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ restore_previous_selection_from_cache
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ build_tree
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.refresh
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ record_previous_selection
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ register_handlers
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.get_selected_bin
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.set_project_title
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.start_inline_rename
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.get_focus_widgets
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.create_tree
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ finalize_pending_rename
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.get_selected_item
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ get_bin_tag
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ trim
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.focus_master_clip
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ set_restoring_flag
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ resolve_bin_parent
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ M.populate_tree
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ add_bin
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ add_master_clip_item
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  build_bin_path ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.get_selection_snapshot
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ restore_previous_selection_from_cache
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ build_tree
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.refresh
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ record_previous_selection
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ register_handlers
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.get_selected_bin
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.set_project_title
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.start_inline_rename
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.get_focus_widgets
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.create_tree
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ finalize_pending_rename
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.get_selected_item
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ trim
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.focus_master_clip
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ set_restoring_flag
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ resolve_bin_parent
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ M.populate_tree
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ add_bin
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ add_master_clip_item
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  get_bin_tag ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  set_restoring_flag ↔ restore_previous_selection_from_cache
    bias-sensitive in [-1.00, -1.00]
  set_restoring_flag ↔ build_tree
    bias-sensitive in [-1.00, -1.00]
  set_restoring_flag ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  set_restoring_flag ↔ record_previous_selection
    bias-sensitive in [-1.00, -1.00]
  set_restoring_flag ↔ register_handlers
    bias-sensitive in [-1.00, -1.00]
  set_restoring_flag ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  set_restoring_flag ↔ M.populate_tree
    bias-sensitive in [-1.00, -1.00]
  set_restoring_flag ↔ add_bin
    bias-sensitive in [-1.00, -1.00]
  set_restoring_flag ↔ M.lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  set_restoring_flag ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  set_restoring_flag ↔ add_master_clip_item
    bias-sensitive in [-1.00, -1.00]
  set_restoring_flag ↔ M.create_tree
    bias-sensitive in [-1.00, -1.00]
  set_restoring_flag ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.get_selection_snapshot
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ restore_previous_selection_from_cache
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ build_tree
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.refresh
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ record_previous_selection
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ register_handlers
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.get_selected_bin
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.set_project_title
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.start_inline_rename
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.get_focus_widgets
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.create_tree
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ finalize_pending_rename
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.get_selected_item
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ trim
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.focus_master_clip
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ resolve_bin_parent
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ M.populate_tree
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ add_bin
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  add_master_clip_item ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  M.populate_tree ↔ restore_previous_selection_from_cache
    bias-sensitive in [-1.00, -1.00]
  M.populate_tree ↔ build_tree
    bias-sensitive in [-1.00, -1.00]
  M.populate_tree ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  M.populate_tree ↔ record_previous_selection
    bias-sensitive in [-1.00, -1.00]
  M.populate_tree ↔ register_handlers
    bias-sensitive in [-1.00, -1.00]
  M.populate_tree ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  M.populate_tree ↔ add_bin
    bias-sensitive in [-1.00, -1.00]
  M.populate_tree ↔ M.lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  M.populate_tree ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.populate_tree ↔ M.create_tree
    bias-sensitive in [-1.00, -1.00]
  M.populate_tree ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  register_handlers ↔ restore_previous_selection_from_cache
    bias-sensitive in [-1.00, -1.00]
  register_handlers ↔ build_tree
    bias-sensitive in [-1.00, -1.00]
  register_handlers ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  register_handlers ↔ record_previous_selection
    bias-sensitive in [-1.00, -1.00]
  register_handlers ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  register_handlers ↔ add_bin
    bias-sensitive in [-1.00, -1.00]
  register_handlers ↔ M.lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  register_handlers ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  register_handlers ↔ M.create_tree
    bias-sensitive in [-1.00, -1.00]
  register_handlers ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.get_selection_snapshot
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ restore_previous_selection_from_cache
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ build_tree
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.refresh
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.get_selected_bin
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.set_project_title
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.start_inline_rename
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.get_focus_widgets
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.create_tree
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ finalize_pending_rename
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.get_selected_item
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ trim
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ M.focus_master_clip
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ resolve_bin_parent
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ add_bin
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  record_previous_selection ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.get_selection_snapshot
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ build_tree
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.refresh
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.get_selected_bin
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.set_project_title
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.start_inline_rename
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.get_focus_widgets
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.create_tree
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ finalize_pending_rename
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.get_selected_item
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ trim
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ M.focus_master_clip
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ resolve_bin_parent
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ add_bin
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  restore_previous_selection_from_cache ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  build_tree ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  build_tree ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  build_tree ↔ add_bin
    bias-sensitive in [-1.00, -1.00]
  build_tree ↔ M.lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  build_tree ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  build_tree ↔ M.create_tree
    bias-sensitive in [-1.00, -1.00]
  build_tree ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  format_duration ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  format_duration ↔ add_bin
    bias-sensitive in [-1.00, -1.00]
  format_duration ↔ M.lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  format_duration ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  format_duration ↔ M.create_tree
    bias-sensitive in [-1.00, -1.00]
  format_duration ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  get_fps_float ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  get_fps_float ↔ add_bin
    bias-sensitive in [-1.00, -1.00]
  get_fps_float ↔ M.lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  get_fps_float ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  get_fps_float ↔ M.create_tree
    bias-sensitive in [-1.00, -1.00]
  M.create_tree ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  M.create_tree ↔ add_bin
    bias-sensitive in [-1.00, -1.00]
  M.create_tree ↔ M.lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  M.create_tree ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.lookup_item_by_tree_id ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  M.lookup_item_by_tree_id ↔ add_bin
    bias-sensitive in [-1.00, -1.00]
  M.lookup_item_by_tree_id ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ M.get_selection_snapshot
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ M.refresh
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ M.get_selected_bin
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ M.set_project_title
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ M.start_inline_rename
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ M.get_focus_widgets
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ finalize_pending_rename
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ M.get_selected_item
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ trim
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ M.focus_master_clip
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ resolve_bin_parent
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  add_bin ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  M.handle ↔ toggle_bin
    bias-sensitive in [-1.00, -1.00]
  M.handle ↔ is_toggle_key
    bias-sensitive in [-1.00, -1.00]
  is_toggle_key ↔ toggle_bin
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ selected_clip:audio
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ clip_has_audio
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ start_inline_rename_after
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ M.show_browser_context_menu
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ M.setup
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ sort_tracks
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ clip_audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ selected_clip:has_video
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ insert_clip
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ selected_clip:has_audio
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ target_video_track
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ collect_name_lookup
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ generate_sequential_label
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ target_audio_track
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  M.create_sequence_in_project ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ selected_clip:audio
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ clip_has_audio
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ start_inline_rename_after
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ M.show_browser_context_menu
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ M.setup
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ clip_audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ selected_clip:has_video
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ insert_clip
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ selected_clip:has_audio
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ target_video_track
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ collect_name_lookup
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ generate_sequential_label
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ target_audio_track
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  sort_tracks ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ selected_clip:audio
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ clip_has_audio
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ start_inline_rename_after
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ M.show_browser_context_menu
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ M.setup
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ clip_audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ insert_clip
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ selected_clip:has_audio
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ target_video_track
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ collect_name_lookup
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ generate_sequential_label
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ target_audio_track
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_video ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ selected_clip:audio
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ clip_has_audio
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ start_inline_rename_after
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ M.show_browser_context_menu
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ M.setup
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ insert_clip
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ selected_clip:has_audio
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ target_video_track
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ collect_name_lookup
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ generate_sequential_label
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ target_audio_track
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  clip_audio_channel_count ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  M.insert_selected_to_timeline ↔ selected_clip:audio
    bias-sensitive in [-1.00, -1.00]
  M.insert_selected_to_timeline ↔ clip_has_audio
    bias-sensitive in [-1.00, -1.00]
  M.insert_selected_to_timeline ↔ start_inline_rename_after
    bias-sensitive in [-1.00, -1.00]
  M.insert_selected_to_timeline ↔ M.show_browser_context_menu
    bias-sensitive in [-1.00, -1.00]
  M.insert_selected_to_timeline ↔ M.setup
    bias-sensitive in [-1.00, -1.00]
  M.insert_selected_to_timeline ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.insert_selected_to_timeline ↔ insert_clip
    bias-sensitive in [-1.00, -1.00]
  M.insert_selected_to_timeline ↔ selected_clip:has_audio
    bias-sensitive in [-1.00, -1.00]
  M.insert_selected_to_timeline ↔ target_video_track
    bias-sensitive in [-1.00, -1.00]
  M.insert_selected_to_timeline ↔ collect_name_lookup
    bias-sensitive in [-1.00, -1.00]
  M.insert_selected_to_timeline ↔ generate_sequential_label
    bias-sensitive in [-1.00, -1.00]
  M.insert_selected_to_timeline ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.insert_selected_to_timeline ↔ target_audio_track
    bias-sensitive in [-1.00, -1.00]
  M.insert_selected_to_timeline ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  M.insert_selected_to_timeline ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  M.insert_selected_to_timeline ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  M.insert_selected_to_timeline ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  insert_clip ↔ selected_clip:audio
    bias-sensitive in [-1.00, -1.00]
  insert_clip ↔ clip_has_audio
    bias-sensitive in [-1.00, -1.00]
  insert_clip ↔ start_inline_rename_after
    bias-sensitive in [-1.00, -1.00]
  insert_clip ↔ M.show_browser_context_menu
    bias-sensitive in [-1.00, -1.00]
  insert_clip ↔ M.setup
    bias-sensitive in [-1.00, -1.00]
  insert_clip ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  insert_clip ↔ selected_clip:has_audio
    bias-sensitive in [-1.00, -1.00]
  insert_clip ↔ target_video_track
    bias-sensitive in [-1.00, -1.00]
  insert_clip ↔ collect_name_lookup
    bias-sensitive in [-1.00, -1.00]
  insert_clip ↔ generate_sequential_label
    bias-sensitive in [-1.00, -1.00]
  insert_clip ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  insert_clip ↔ target_audio_track
    bias-sensitive in [-1.00, -1.00]
  insert_clip ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  insert_clip ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  insert_clip ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  insert_clip ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  selected_clip:audio ↔ clip_has_audio
    bias-sensitive in [-1.00, -1.00]
  selected_clip:audio ↔ start_inline_rename_after
    bias-sensitive in [-1.00, -1.00]
  selected_clip:audio ↔ M.show_browser_context_menu
    bias-sensitive in [-1.00, -1.00]
  selected_clip:audio ↔ M.setup
    bias-sensitive in [-1.00, -1.00]
  selected_clip:audio ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  selected_clip:audio ↔ selected_clip:has_audio
    bias-sensitive in [-1.00, -1.00]
  selected_clip:audio ↔ target_video_track
    bias-sensitive in [-1.00, -1.00]
  selected_clip:audio ↔ collect_name_lookup
    bias-sensitive in [-1.00, -1.00]
  selected_clip:audio ↔ generate_sequential_label
    bias-sensitive in [-1.00, -1.00]
  selected_clip:audio ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  selected_clip:audio ↔ target_audio_track
    bias-sensitive in [-1.00, -1.00]
  selected_clip:audio ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  selected_clip:audio ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  selected_clip:audio ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  selected_clip:audio ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_audio ↔ clip_has_audio
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_audio ↔ start_inline_rename_after
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_audio ↔ M.show_browser_context_menu
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_audio ↔ M.setup
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_audio ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_audio ↔ target_video_track
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_audio ↔ collect_name_lookup
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_audio ↔ generate_sequential_label
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_audio ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_audio ↔ target_audio_track
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_audio ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_audio ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_audio ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  selected_clip:has_audio ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  target_video_track ↔ clip_has_audio
    bias-sensitive in [-1.00, -1.00]
  target_video_track ↔ start_inline_rename_after
    bias-sensitive in [-1.00, -1.00]
  target_video_track ↔ M.show_browser_context_menu
    bias-sensitive in [-1.00, -1.00]
  target_video_track ↔ M.setup
    bias-sensitive in [-1.00, -1.00]
  target_video_track ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  target_video_track ↔ collect_name_lookup
    bias-sensitive in [-1.00, -1.00]
  target_video_track ↔ generate_sequential_label
    bias-sensitive in [-1.00, -1.00]
  target_video_track ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  target_video_track ↔ target_audio_track
    bias-sensitive in [-1.00, -1.00]
  target_video_track ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  target_video_track ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  target_video_track ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  target_video_track ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  clip_has_audio ↔ start_inline_rename_after
    bias-sensitive in [-1.00, -1.00]
  clip_has_audio ↔ M.show_browser_context_menu
    bias-sensitive in [-1.00, -1.00]
  clip_has_audio ↔ M.setup
    bias-sensitive in [-1.00, -1.00]
  clip_has_audio ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  clip_has_audio ↔ collect_name_lookup
    bias-sensitive in [-1.00, -1.00]
  clip_has_audio ↔ generate_sequential_label
    bias-sensitive in [-1.00, -1.00]
  clip_has_audio ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  clip_has_audio ↔ target_audio_track
    bias-sensitive in [-1.00, -1.00]
  clip_has_audio ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  clip_has_audio ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  clip_has_audio ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  clip_has_audio ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  collect_name_lookup ↔ start_inline_rename_after
    bias-sensitive in [-1.00, -1.00]
  collect_name_lookup ↔ M.show_browser_context_menu
    bias-sensitive in [-1.00, -1.00]
  collect_name_lookup ↔ M.setup
    bias-sensitive in [-1.00, -1.00]
  collect_name_lookup ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  collect_name_lookup ↔ generate_sequential_label
    bias-sensitive in [-1.00, -1.00]
  collect_name_lookup ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  collect_name_lookup ↔ target_audio_track
    bias-sensitive in [-1.00, -1.00]
  collect_name_lookup ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  collect_name_lookup ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  collect_name_lookup ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  collect_name_lookup ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  start_inline_rename_after ↔ M.show_browser_context_menu
    bias-sensitive in [-1.00, -1.00]
  start_inline_rename_after ↔ M.setup
    bias-sensitive in [-1.00, -1.00]
  start_inline_rename_after ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  start_inline_rename_after ↔ generate_sequential_label
    bias-sensitive in [-1.00, -1.00]
  start_inline_rename_after ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  start_inline_rename_after ↔ target_audio_track
    bias-sensitive in [-1.00, -1.00]
  start_inline_rename_after ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  start_inline_rename_after ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  start_inline_rename_after ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  start_inline_rename_after ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  generate_sequential_label ↔ M.show_browser_context_menu
    bias-sensitive in [-1.00, -1.00]
  generate_sequential_label ↔ M.setup
    bias-sensitive in [-1.00, -1.00]
  generate_sequential_label ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  generate_sequential_label ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  generate_sequential_label ↔ target_audio_track
    bias-sensitive in [-1.00, -1.00]
  generate_sequential_label ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  generate_sequential_label ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  generate_sequential_label ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  generate_sequential_label ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  M.show_browser_context_menu ↔ M.setup
    bias-sensitive in [-1.00, -1.00]
  M.show_browser_context_menu ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.show_browser_context_menu ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.show_browser_context_menu ↔ target_audio_track
    bias-sensitive in [-1.00, -1.00]
  M.show_browser_context_menu ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  M.show_browser_context_menu ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  M.show_browser_context_menu ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  M.show_browser_context_menu ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  M.delete_selected_items ↔ M.setup
    bias-sensitive in [-1.00, -1.00]
  M.delete_selected_items ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.delete_selected_items ↔ target_audio_track
    bias-sensitive in [-1.00, -1.00]
  M.delete_selected_items ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  M.delete_selected_items ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  M.delete_selected_items ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  M.delete_selected_items ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  M.setup ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.setup ↔ target_audio_track
    bias-sensitive in [-1.00, -1.00]
  M.setup ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  M.setup ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  M.setup ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  M.setup ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  target_audio_track ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  target_audio_track ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  target_audio_track ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  target_audio_track ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  target_audio_track ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  show_browser_background_menu ↔ M.create_bin_in_root
    bias-sensitive in [-1.00, -1.00]
  show_browser_background_menu ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  show_browser_background_menu ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  show_browser_background_menu ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  M.create_bin_in_root ↔ selected_clip:audio_channel_count
    bias-sensitive in [-1.00, -1.00]
  M.create_bin_in_root ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  M.create_bin_in_root ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  selected_clip:audio_channel_count ↔ sequence_defaults
    bias-sensitive in [-1.00, -1.00]
  selected_clip:audio_channel_count ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  sequence_defaults ↔ clip_has_video
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ M.get_selection_snapshot
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ M.refresh
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ M.get_selected_bin
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ M.set_project_title
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ M.start_inline_rename
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ M.get_focus_widgets
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ finalize_pending_rename
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ M.get_selected_item
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ trim
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ resolve_bin_parent
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  M.focus_master_clip ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ M.refresh
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ M.get_selected_bin
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ M.set_project_title
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ M.start_inline_rename
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ M.get_focus_widgets
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ finalize_pending_rename
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ M.get_selected_item
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ trim
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ resolve_bin_parent
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  M.get_selection_snapshot ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ M.refresh
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ M.get_selected_bin
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ M.set_project_title
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ M.start_inline_rename
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ M.get_focus_widgets
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ finalize_pending_rename
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ M.get_selected_item
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ trim
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  resolve_bin_parent ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ M.refresh
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ M.get_selected_bin
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ M.set_project_title
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ M.start_inline_rename
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ M.get_focus_widgets
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ M.get_selected_item
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ trim
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  finalize_pending_rename ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ M.refresh
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ M.get_selected_bin
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ M.set_project_title
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ M.start_inline_rename
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ M.get_focus_widgets
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ trim
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_item ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ M.refresh
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ M.set_project_title
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ M.start_inline_rename
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ M.get_focus_widgets
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ trim
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_bin ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ M.refresh
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ M.start_inline_rename
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ M.get_focus_widgets
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ trim
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  M.set_project_title ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ M.start_inline_rename
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ M.get_focus_widgets
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ trim
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  M.refresh ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ M.get_focus_widgets
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ lookup_item_by_tree_id
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ trim
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  M.start_inline_rename ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ M.get_focus_widgets
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ trim
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  lookup_item_by_tree_id ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ trim
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ register_handler
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  M.get_focus_widgets ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ set_bin_parent
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ trim
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  register_handler ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ defer_to_ui
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ trim
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  set_bin_parent ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ handle_tree_editor_closed
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ trim
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  defer_to_ui ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ activate_item
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ trim
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  handle_tree_editor_closed ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ trim
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ ensure_command_listener
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  activate_item ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ M.focus_bin
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ trim
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  ensure_command_listener ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ trim
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  M.focus_bin ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  trim ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  trim ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  trim ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  trim ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  trim ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  trim ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  trim ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  trim ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  trim ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  trim ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  trim ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  trim ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  trim ↔ focus_tree_widget
    bias-sensitive in [-1.00, -1.00]
  trim ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  trim ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  trim ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  trim ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  trim ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  trim ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  trim ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ M.get_selected_master_clip
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  focus_tree_widget ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ resolve_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_master_clip ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  resolve_tree_item ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  resolve_tree_item ↔ M.activate_selection
    bias-sensitive in [-1.00, -1.00]
  resolve_tree_item ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  resolve_tree_item ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  resolve_tree_item ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  resolve_tree_item ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  resolve_tree_item ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  resolve_tree_item ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  resolve_tree_item ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  resolve_tree_item ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  resolve_tree_item ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  resolve_tree_item ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  resolve_tree_item ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  M.activate_selection ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  M.activate_selection ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  M.activate_selection ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  M.activate_selection ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  M.activate_selection ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.activate_selection ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  M.activate_selection ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  M.activate_selection ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  M.activate_selection ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  M.activate_selection ↔ handle_tree_drop
    bias-sensitive in [-1.00, -1.00]
  M.activate_selection ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.activate_selection ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  M.activate_selection ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  M.activate_selection ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.activate_selection ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  M.activate_selection ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  handle_tree_drop ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  handle_tree_drop ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  handle_tree_drop ↔ selection_context
    bias-sensitive in [-1.00, -1.00]
  handle_tree_drop ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  handle_tree_drop ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  handle_tree_drop ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  handle_tree_drop ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  handle_tree_drop ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  handle_tree_drop ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  handle_tree_drop ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  handle_tree_drop ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  handle_tree_drop ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  handle_tree_drop ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  handle_tree_drop ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  handle_tree_drop ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  selection_context ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  selection_context ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  selection_context ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  selection_context ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  selection_context ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  selection_context ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  selection_context ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  selection_context ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  selection_context ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  selection_context ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  selection_context ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  selection_context ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  selection_context ↔ is_descendant
    bias-sensitive in [-1.00, -1.00]
  selection_context ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  is_descendant ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  is_descendant ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  is_descendant ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  is_descendant ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  is_descendant ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  is_descendant ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  is_descendant ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  is_descendant ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  is_descendant ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  is_descendant ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  is_descendant ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  is_descendant ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  is_descendant ↔ handle_tree_key_event
    bias-sensitive in [-1.00, -1.00]
  handle_tree_key_event ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  handle_tree_key_event ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  handle_tree_key_event ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  handle_tree_key_event ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  handle_tree_key_event ↔ populate_tree
    bias-sensitive in [-1.00, -1.00]
  handle_tree_key_event ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  handle_tree_key_event ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  handle_tree_key_event ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  handle_tree_key_event ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  handle_tree_key_event ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  handle_tree_key_event ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  handle_tree_key_event ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  populate_tree ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  populate_tree ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  populate_tree ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  populate_tree ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  populate_tree ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  populate_tree ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  populate_tree ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  populate_tree ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  populate_tree ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  populate_tree ↔ handle_tree_item_changed
    bias-sensitive in [-1.00, -1.00]
  populate_tree ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  handle_tree_item_changed ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  handle_tree_item_changed ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  handle_tree_item_changed ↔ M.focus_sequence
    bias-sensitive in [-1.00, -1.00]
  handle_tree_item_changed ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  handle_tree_item_changed ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  handle_tree_item_changed ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  handle_tree_item_changed ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  handle_tree_item_changed ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  handle_tree_item_changed ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  handle_tree_item_changed ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.focus_sequence ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  M.focus_sequence ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  M.focus_sequence ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.focus_sequence ↔ M.create
    bias-sensitive in [-1.00, -1.00]
  M.focus_sequence ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  M.focus_sequence ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  M.focus_sequence ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.focus_sequence ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  M.focus_sequence ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.create ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  M.create ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  M.create ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.create ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  M.create ↔ M.get_selected_media
    bias-sensitive in [-1.00, -1.00]
  M.create ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.create ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  M.create ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_media ↔ format_duration
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_media ↔ M.insert_selected_to_timeline
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_media ↔ M.delete_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_media ↔ get_fps_float
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_media ↔ show_browser_background_menu
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_media ↔ format_date
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_media ↔ store_tree_item
    bias-sensitive in [-1.00, -1.00]
  M.update_selection ↔ decode_metadata
    bias-sensitive in [-1.00, -1.00]
  M.update_selection ↔ M.set_on_selection_changed
    bias-sensitive in [-1.00, -1.00]
  M.update_selection ↔ M.clear_selection
    bias-sensitive in [-1.00, -1.00]
  M.update_selection ↔ normalize_master_clip
    bias-sensitive in [-1.00, -1.00]
  M.update_selection ↔ M.get_selected_items
    bias-sensitive in [-1.00, -1.00]
  M.update_selection ↔ normalize_timeline
    bias-sensitive in [-1.00, -1.00]
  M.update_selection ↔ M.normalize_selection
    bias-sensitive in [-1.00, -1.00]
  decode_metadata ↔ M.set_on_selection_changed
    bias-sensitive in [-1.00, -1.00]
  decode_metadata ↔ M.clear_selection
    bias-sensitive in [-1.00, -1.00]
  decode_metadata ↔ normalize_master_clip
    bias-sensitive in [-1.00, -1.00]
  decode_metadata ↔ M.get_selected_items
    bias-sensitive in [-1.00, -1.00]
  decode_metadata ↔ normalize_timeline
    bias-sensitive in [-1.00, -1.00]
  decode_metadata ↔ M.normalize_selection
    bias-sensitive in [-1.00, -1.00]
  normalize_master_clip ↔ M.set_on_selection_changed
    bias-sensitive in [-1.00, -1.00]
  normalize_master_clip ↔ M.clear_selection
    bias-sensitive in [-1.00, -1.00]
  normalize_master_clip ↔ M.get_selected_items
    bias-sensitive in [-1.00, -1.00]
  normalize_master_clip ↔ normalize_timeline
    bias-sensitive in [-1.00, -1.00]
  normalize_master_clip ↔ M.normalize_selection
    bias-sensitive in [-1.00, -1.00]
  normalize_timeline ↔ M.set_on_selection_changed
    bias-sensitive in [-1.00, -1.00]
  normalize_timeline ↔ M.clear_selection
    bias-sensitive in [-1.00, -1.00]
  normalize_timeline ↔ M.get_selected_items
    bias-sensitive in [-1.00, -1.00]
  normalize_timeline ↔ M.normalize_selection
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_items ↔ M.set_on_selection_changed
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_items ↔ M.clear_selection
    bias-sensitive in [-1.00, -1.00]
  M.get_selected_items ↔ M.normalize_selection
    bias-sensitive in [-1.00, -1.00]
  M.set_on_selection_changed ↔ M.clear_selection
    bias-sensitive in [-1.00, -1.00]
  M.set_on_selection_changed ↔ M.normalize_selection
    bias-sensitive in [-1.00, -1.00]
  M.normalize_selection ↔ M.clear_selection
    bias-sensitive in [-1.00, -1.00]

Done.
joe@joelap16 ui % 
coupling
implement and let
run
give me the new script
joe@joelap16 ui % ../../../scripts/lua_mod_analyze.py project_browser
MODULE ANALYSIS REPORT

Declared modules:

Bias-sensitive seams:

M.create_tree ↔ record_previous_selection
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ restore_previous_selection_from_cache
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ get_fps_float
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ M.create_tree
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ store_tree_item
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ build_tree
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ M.populate_tree
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ format_duration
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ M.lookup_item_by_tree_id
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ add_bin
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ build_bin_path
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ register_handlers
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ format_date
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ resolve_tree_item
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ add_master_clip_item
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ register_handler
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ get_bin_tag
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ set_restoring_flag
  coupling=0.00, bias-sensitive in [1.00, 1.00]
record_previous_selection ↔ defer_to_ui
  coupling=0.00, bias-sensitive in [1.00, 1.00]
record_previous_selection ↔ record_previous_selection
  coupling=0.00, bias-sensitive in [1.00, 1.00]
record_previous_selection ↔ handle_tree_editor_closed
  coupling=0.00, bias-sensitive in [1.00, 1.00]
record_previous_selection ↔ M.focus_master_clip
  coupling=0.00, bias-sensitive in [1.00, 1.00]
record_previous_selection ↔ restore_previous_selection_from_cache
  coupling=0.00, bias-sensitive in [1.00, 1.00]
record_previous_selection ↔ M.get_selection_snapshot
  coupling=0.00, bias-sensitive in [1.00, 1.00]
record_previous_selection ↔ selection_context
  coupling=0.00, bias-sensitive in [1.00, 1.00]
record_previous_selection ↔ store_tree_item
  coupling=0.00, bias-sensitive in [1.00, 1.00]
record_previous_selection ↔ M.get_selected_master_clip
  coupling=0.00, bias-sensitive in [1.00, 1.00]
record_previous_selection ↔ ensure_command_listener
  coupling=0.00, bias-sensitive in [1.00, 1.00]
record_previous_selection ↔ M.insert_selected_to_timeline
  coupling=0.00, bias-sensitive in [1.00, 1.00]
record_previous_selection ↔ activate_item
  coupling=0.00, bias-sensitive in [1.00, 1.00]

Utility sinks (high fan-out, low cohesion):
  record_previous_selection (fanout=165, role=wiring)
  build_bin_path (fanout=165, role=wiring)
  add_master_clip_item (fanout=165, role=wiring)
  get_bin_tag (fanout=165, role=wiring)
  restore_previous_selection_from_cache (fanout=165, role=wiring)
  add_bin (fanout=165, role=wiring)
  defer_to_ui (fanout=151, role=wiring)
  finalize_pending_rename (fanout=151, role=wiring)
  resolve_bin_parent (fanout=151, role=wiring)
  is_descendant (fanout=151, role=wiring)
joe@joelap16 ui % 
joe@joelap16 ui % ../../../scripts/lua_mod_analyze.py project_browser
MODULE ANALYSIS REPORT

Declared modules:

Bias-sensitive seams:

restore_previous_selection_from_cache ↔ M.start_inline_rename
  coupling=0.00, bias-sensitive in [1.00, 1.00]
restore_previous_selection_from_cache ↔ M.insert_selected_to_timeline
  coupling=0.00, bias-sensitive in [1.00, 1.00]
restore_previous_selection_from_cache ↔ set_restoring_flag
  coupling=0.00, bias-sensitive in [1.00, 1.00]
restore_previous_selection_from_cache ↔ M.get_selected_master_clip
  coupling=0.00, bias-sensitive in [1.00, 1.00]
restore_previous_selection_from_cache ↔ M.delete_selected_items
  coupling=0.00, bias-sensitive in [1.00, 1.00]
restore_previous_selection_from_cache ↔ restore_previous_selection_from_cache
  coupling=0.00, bias-sensitive in [1.00, 1.00]
restore_previous_selection_from_cache ↔ show_browser_background_menu
  coupling=0.00, bias-sensitive in [1.00, 1.00]
record_previous_selection ↔ record_previous_selection
  coupling=0.00, bias-sensitive in [1.00, 1.00]
register_handlers ↔ resolve_tree_item
  coupling=0.00, bias-sensitive in [1.00, 1.00]
register_handlers ↔ register_handler
  coupling=0.00, bias-sensitive in [1.00, 1.00]
add_bin ↔ store_tree_item
  coupling=0.00, bias-sensitive in [1.00, 1.00]
add_bin ↔ add_bin
  coupling=0.00, bias-sensitive in [1.00, 1.00]
add_bin ↔ format_duration
  coupling=0.00, bias-sensitive in [1.00, 1.00]
add_bin ↔ get_fps_float
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ build_tree
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_tree ↔ register_handlers
  coupling=0.00, bias-sensitive in [1.00, 1.00]
add_master_clip_item ↔ get_bin_tag
  coupling=0.00, bias-sensitive in [1.00, 1.00]
add_master_clip_item ↔ store_tree_item
  coupling=0.00, bias-sensitive in [1.00, 1.00]
add_master_clip_item ↔ add_master_clip_item
  coupling=0.00, bias-sensitive in [1.00, 1.00]
add_master_clip_item ↔ format_date
  coupling=0.00, bias-sensitive in [1.00, 1.00]
add_master_clip_item ↔ format_duration
  coupling=0.00, bias-sensitive in [1.00, 1.00]
add_master_clip_item ↔ get_fps_float
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.handle ↔ is_toggle_key
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.handle ↔ toggle_bin
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_bin_in_root ↔ generate_sequential_label
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_bin_in_root ↔ collect_name_lookup
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_bin_in_root ↔ start_inline_rename_after
  coupling=0.00, bias-sensitive in [1.00, 1.00]
clip_has_audio ↔ clip_audio_channel_count
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_sequence_in_project ↔ generate_sequential_label
  coupling=0.00, bias-sensitive in [1.00, 1.00]
M.create_sequence_in_project ↔ collect_name_lookup
  coupling=0.00, bias-sensitive in [1.00, 1.00]

Utility sinks (high fan-out, low cohesion):
  M.create (fanout=57, role=wiring)
  restore_previous_selection_from_cache (fanout=30, role=wiring)
  register_handlers (fanout=30, role=wiring)
  M.show_browser_context_menu (fanout=25, role=wiring)
  resolve_bin_parent (fanout=17, role=wiring)
  finalize_pending_rename (fanout=17, role=wiring)
  M.create_sequence_in_project (fanout=14, role=wiring)
  M.create_bin_in_root (fanout=13, role=wiring)
  add_master_clip_item (fanout=12, role=wiring)
  record_previous_selection (fanout=11, role=wiring)
joe@joelap16 ui % 
still zero
give me a download link for the updated script
joe@joelap16 ui % ../../../scripts/lua_mod_analyze.py project_browser
MODULE ANALYSIS REPORT

add_bin ↔ format_duration  coupling=0.00  bias-sensitive [1.00,1.00]
add_bin ↔ add_bin  coupling=0.44  bias-sensitive [-0.36,0.84]
add_bin ↔ get_fps_float  coupling=0.00  bias-sensitive [1.00,1.00]
add_bin ↔ store_tree_item  coupling=0.00  bias-sensitive [1.00,1.00]
restore_previous_selection_from_cache ↔ set_restoring_flag  coupling=0.00  bias-sensitive [1.00,1.00]
restore_previous_selection_from_cache ↔ restore_previous_selection_from_cache  coupling=0.03  bias-sensitive [1.00,1.00]
restore_previous_selection_from_cache ↔ show_browser_background_menu  coupling=0.06  bias-sensitive [1.00,1.00]
restore_previous_selection_from_cache ↔ M.delete_selected_items  coupling=0.03  bias-sensitive [1.00,1.00]
restore_previous_selection_from_cache ↔ M.insert_selected_to_timeline  coupling=0.12  bias-sensitive [0.91,1.00]
restore_previous_selection_from_cache ↔ M.start_inline_rename  coupling=0.12  bias-sensitive [0.91,1.00]
restore_previous_selection_from_cache ↔ M.get_selected_master_clip  coupling=0.00  bias-sensitive [1.00,1.00]
register_handlers ↔ resolve_tree_item  coupling=0.13  bias-sensitive [0.87,1.00]
register_handlers ↔ register_handler  coupling=0.00  bias-sensitive [1.00,1.00]
build_bin_path ↔ build_bin_path  coupling=1.00  bias-sensitive [-1.00,-1.00]
record_previous_selection ↔ record_previous_selection  coupling=0.36  bias-sensitive [-0.04,1.00]
add_master_clip_item ↔ format_duration  coupling=0.00  bias-sensitive [1.00,1.00]
add_master_clip_item ↔ get_fps_float  coupling=0.00  bias-sensitive [1.00,1.00]
add_master_clip_item ↔ store_tree_item  coupling=0.00  bias-sensitive [1.00,1.00]
add_master_clip_item ↔ get_bin_tag  coupling=0.05  bias-sensitive [1.00,1.00]
add_master_clip_item ↔ format_date  coupling=0.00  bias-sensitive [1.00,1.00]
add_master_clip_item ↔ add_master_clip_item  coupling=0.32  bias-sensitive [0.11,1.00]
M.create_tree ↔ register_handlers  coupling=0.00  bias-sensitive [1.00,1.00]
M.create_tree ↔ build_tree  coupling=0.00  bias-sensitive [1.00,1.00]
M.handle ↔ is_toggle_key  coupling=0.04  bias-sensitive [1.00,1.00]
M.handle ↔ toggle_bin  coupling=0.00  bias-sensitive [1.00,1.00]
target_video_track ↔ sort_tracks  coupling=0.00  bias-sensitive [1.00,1.00]
selected_clip:has_video ↔ clip_has_video  coupling=0.67  bias-sensitive [-1.00,-0.08]
selected_clip:has_audio ↔ clip_has_audio  coupling=0.67  bias-sensitive [-1.00,-0.08]
M.show_browser_context_menu ↔ M.insert_selected_to_timeline  coupling=0.00  bias-sensitive [1.00,1.00]
M.show_browser_context_menu ↔ show_browser_background_menu  coupling=0.07  bias-sensitive [1.00,1.00]
M.show_browser_context_menu ↔ M.delete_selected_items  coupling=0.04  bias-sensitive [1.00,1.00]
M.create_sequence_in_project ↔ generate_sequential_label  coupling=0.00  bias-sensitive [1.00,1.00]
M.create_sequence_in_project ↔ sequence_defaults  coupling=0.08  bias-sensitive [1.00,1.00]
M.create_sequence_in_project ↔ start_inline_rename_after  coupling=0.00  bias-sensitive [1.00,1.00]
M.create_sequence_in_project ↔ collect_name_lookup  coupling=0.00  bias-sensitive [1.00,1.00]
M.create_bin_in_root ↔ generate_sequential_label  coupling=0.00  bias-sensitive [1.00,1.00]
M.create_bin_in_root ↔ start_inline_rename_after  coupling=0.00  bias-sensitive [1.00,1.00]
M.create_bin_in_root ↔ collect_name_lookup  coupling=0.00  bias-sensitive [1.00,1.00]
clip_has_audio ↔ clip_audio_channel_count  coupling=0.64  bias-sensitive [-1.00,0.04]
selected_clip:audio_channel_count ↔ clip_audio_channel_count  coupling=0.64  bias-sensitive [-1.00,0.04]
target_audio_track ↔ sort_tracks  coupling=0.00  bias-sensitive [1.00,1.00]
resolve_tree_item ↔ lookup_item_by_tree_id  coupling=0.00  bias-sensitive [1.00,1.00]
M.activate_selection ↔ activate_item  coupling=0.14  bias-sensitive [0.84,1.00]
M.activate_selection ↔ M.get_selected_item  coupling=0.17  bias-sensitive [0.72,1.00]
resolve_bin_parent ↔ is_descendant  coupling=0.00  bias-sensitive [1.00,1.00]
resolve_bin_parent ↔ defer_to_ui  coupling=0.00  bias-sensitive [1.00,1.00]
resolve_bin_parent ↔ resolve_bin_parent  coupling=0.15  bias-sensitive [0.80,1.00]
resolve_bin_parent ↔ M.focus_bin  coupling=0.00  bias-sensitive [1.00,1.00]
resolve_bin_parent ↔ set_bin_parent  coupling=0.33  bias-sensitive [0.08,1.00]
resolve_bin_parent ↔ M.refresh  coupling=0.00  bias-sensitive [1.00,1.00]
handle_tree_editor_closed ↔ finalize_pending_rename  coupling=0.00  bias-sensitive [1.00,1.00]
handle_tree_item_changed ↔ trim  coupling=0.00  bias-sensitive [1.00,1.00]
M.focus_sequence ↔ M.activate_selection  coupling=0.00  bias-sensitive [1.00,1.00]
handle_tree_drop ↔ lookup_item_by_tree_id  coupling=0.00  bias-sensitive [1.00,1.00]
finalize_pending_rename ↔ trim  coupling=0.00  bias-sensitive [1.00,1.00]
activate_item ↔ selection_context  coupling=0.20  bias-sensitive [0.60,1.00]
M.create ↔ resolve_tree_item  coupling=0.17  bias-sensitive [0.73,1.00]
M.create ↔ handle_tree_editor_closed  coupling=0.17  bias-sensitive [0.73,1.00]
M.create ↔ handle_tree_item_changed  coupling=0.14  bias-sensitive [0.85,1.00]
M.create ↔ ensure_command_listener  coupling=0.00  bias-sensitive [1.00,1.00]
M.create ↔ populate_tree  coupling=0.00  bias-sensitive [1.00,1.00]
M.create ↔ handle_tree_drop  coupling=0.14  bias-sensitive [0.85,1.00]
M.create ↔ handle_tree_key_event  coupling=0.17  bias-sensitive [0.73,1.00]
M.create ↔ register_handler  coupling=0.00  bias-sensitive [1.00,1.00]
M.normalize_selection ↔ normalize_timeline  coupling=0.00  bias-sensitive [1.00,1.00]
M.normalize_selection ↔ normalize_master_clip  coupling=0.08  bias-sensitive [1.00,1.00]
normalize_master_clip ↔ decode_metadata  coupling=0.02  bias-sensitive [1.00,1.00]
M.update_selection ↔ M.normalize_selection  coupling=0.05  bias-sensitive [1.00,1.00]
joe@joelap16 ui % 
joe@joelap16 ui % ../../../scripts/lua_mod_analyze.py project_browser
MODULE ANALYSIS REPORT

selected_clip:has_video ↔ clip_has_video  coupling=0.67  bias-sensitive [-1.00,-0.08]
clip_has_audio ↔ clip_audio_channel_count  coupling=0.64  bias-sensitive [-1.00,0.04]
selected_clip:has_audio ↔ clip_has_audio  coupling=0.67  bias-sensitive [-1.00,-0.08]
selected_clip:audio_channel_count ↔ clip_audio_channel_count  coupling=0.64  bias-sensitive [-1.00,0.04]
M.activate_selection ↔ M.get_selected_item  coupling=0.17  bias-sensitive [0.72,1.00]
activate_item ↔ selection_context  coupling=0.20  bias-sensitive [0.60,1.00]
M.create ↔ handle_tree_editor_closed  coupling=0.17  bias-sensitive [0.73,1.00]
M.create ↔ handle_tree_key_event  coupling=0.17  bias-sensitive [0.73,1.00]
M.create ↔ resolve_tree_item  coupling=0.17  bias-sensitive [0.73,1.00]
resolve_bin_parent ↔ set_bin_parent  coupling=0.33  bias-sensitive [0.08,1.00]
joe@joelap16 ui % 
cluster
joe@joelap16 ui % ../../../scripts/lua_mod_analyze.py project_browser
CLUSTERS (coupling ≥ 0.35)

Cluster 1 (4 functions):
  clip_audio_channel_count
  clip_has_audio
  selected_clip:audio_channel_count
  selected_clip:has_audio

Cluster 2 (2 functions):
  clip_has_video
  selected_clip:has_video
this chat is going too slowly now. please give me a context to transition to a new chat
what's a pinned working assumptions block
pinned please
why am i not getting alternative cluster suggestions
lua_mod_analyze.py
Python
what do you think of these modifications
This review is solid, and it explains the current behavior without contradicting what you’ve already learned from the tool. I agree with its core diagnosis, and more importantly, it points to **why your expectations are reasonable even though the current output is sparse**.

Let me reconcile this cleanly and then propose a **tight, staged response** that doesn’t blow up scope or undo the discipline you’ve established.

---

## Where the review is exactly right

### 1. You’ve hit the limit of *identifier-as-token* analysis

You are currently extracting **lexical identifiers**, not **semantic anchors**. As the review notes, this:


python
IDENT_RE = r"\b([a-zA-Z_][a-zA-Z0-9_]*)\b"


treats:

* loop vars
* temporaries
* generic nouns

as equal to:

* domain objects
* state roots
* architectural context

That guarantees dilution. The fact that *only* the clip/audio helpers cluster strongly is actually proof that the rest of the signal is being drowned, not that it isn’t there.

So yes: **“mostly zero” coupling is expected under this signal model**.

---

### 2. One-way call penalties are mismatched to UI reality

This rule:


python
if b in calls[a] and a not in calls[b]:
    score -= 0.3


implicitly encodes a backend-style assumption: symmetry implies cohesion.

In UI and orchestration code, that assumption is wrong. Directionality is the norm, not the exception. Penalizing it this hard suppresses exactly the seams you care about.

The review is correct: this penalty is currently **masking legitimate cohesion**, not filtering glue.

---

### 3. Context tables are the missing structural carrier

This is the most important point in the review, and it aligns perfectly with your goals.

Your codebase’s real structure is carried by things like:

* tree_context.*
* browser_state.*
* M.*

Those are **implicit modules**. Today, the tool sees them as unrelated strings.

So the tool is faithfully answering:

> “Where does cohesion exist *without* context?”

And the answer is: almost nowhere.

That’s not wrong. It’s incomplete.

---

## Where I want to be very precise

### You do *not* need to jump straight to community detection

The review suggests Louvain / Leiden, threshold sweeps, etc. Those will indeed produce more partitions, but they also risk violating your core constraint:

> discover structural refactor seams, not invent intent

Community detection will happily cluster glue if it’s dense enough.

There is a **smaller, safer step** that unlocks alternatives *without* changing the clustering model.

---

## The right next move (in order)

### Step 1: Promote table.field to a first-class signal

This is the single highest-leverage change.

Mechanically:

* Extract X.Y access patterns
* Treat X as a **context root**
* Count shared roots between functions
* Give this signal *more weight* than raw identifiers

This immediately surfaces real cohesion without guessing semantics.

Crucially:
This does **not** require new algorithms. It plugs directly into your existing coupling function.

---

### Step 2: Reduce or remove the one-way call penalty

Change -0.3 to something like -0.05, or gate it behind fan-out.

This aligns the model with UI code reality and stops suppressing valid clusters.

---

### Step 3: Weight identifiers by rarity (optional but clean)

This is a refinement, not a rewrite:

* Precompute global identifier frequencies
* Rare identifiers contribute more
* Common ones fade into noise

This preserves your current approach while making it semantic instead of lexical.

---

### Step 4: *Then* surface alternatives as **tension**, not new clusters

Only after the above will alternative partitions actually exist.

And when they do, the right way to surface them is not:

> “Here is another clustering”

but:

> “Here is where this cluster could plausibly fracture or regroup”

Using:

* near-threshold edges
* bias-sensitive edges
* context-root overlaps

This keeps the tool honest and puts you back in the design seat.

---

## The key takeaway

The review’s bottom line is correct:

> The tool is structurally sound but still missing semantic carriers.

Your work so far was not wasted or misguided. It got you to the point where **the remaining missing pieces are clear and mechanical**, not philosophical.

You’re exactly where a good analysis tool *should* be before it becomes useful for architecture instead of trivia.

---

## Suggested immediate next action (tight)

I recommend this order:

1. **Add context-root extraction (X.Y → X)**
2. **Relax the directional penalty**
3. Re-run on the same code
4. Only then revisit “alternative cluster suggestions”

If you want, I can:

* spec context-root extraction precisely (regexes, weights, edge cases), or
* sketch the revised coupling function with all changes applied but no new machinery

Say which, and we’ll proceed cleanly.
this is new chat's analysis and where it wants to go. what do you think?
lua_mod_analyze_cluster_centric_clean.py
Python
is this still isomorphic to what you built 
lua_mod_analyze.py
Python
what do you think about this: Short answer: **it’s directionally correct, but the attribution is still overstating causality.** The message is *better* than the logger / debug cases, but it’s not yet maximally useful.

Let’s be precise.

---

## Is the message *correct*?

### 1. “organized around M.create”

Yes.
That is strongly supported by degree, call structure, and LOC dominance.

### 2. “shared ‘keymap’ context usage”

**Partially correct, but misleading in emphasis.**

What this really means structurally is:

* keymap is **project-level infrastructure**, not language runtime
* It is *less* ubiquitous than debug
* It *is* used disproportionately in this cluster
* Therefore it survives rarity + coverage filters

So the model is not *wrong* to notice keymap.

However:

> keymap is still **coordination infrastructure**, not a domain responsibility.

It explains *why these functions interact*, but not *what responsibility binds them*.

So the sentence is technically accurate but **over-claims semantic causation**.

---

## Is it as useful as it can be?

Not yet. Here’s why.

Right now, the explanation implies:

> “This cluster exists because of keymap usage.”

But the more accurate architectural reading is:

> “This cluster exists because M.create coordinates lifecycle and registration, and keymap interaction is one facet of that coordination.”

In other words:

* keymap is a **symptom of orchestration**
* not the **driver of cohesion**

---

## What the tool is missing (final subtlety)

You now need one more distinction in the *explanation layer*:

### **Coordination contexts vs domain contexts**

Context roots fall into (at least) two explanatory classes:

1. **Domain-bearing contexts**

   * tree_context
   * selection_context
   * browser_state
     These *define responsibility*.

2. **Coordination / integration contexts**

   * keymap
   * event_bus
   * command_registry
     These indicate *how* things are wired, not *what* they are about.

keymap is clearly category (2).

---

## The correct interpretation of *this* cluster

Given everything the tool knows, the most honest explanation would be:

> “This cluster is organized around M.create, with cohesion driven primarily by orchestration and registration logic rather than a shared domain context.”

That is **more useful** than naming keymap, even though keymap is technically salient.

---

## What to do about it (without overfitting)

You have two clean options. Only one more step is needed.

### Option A (recommended): downgrade coordination contexts in explanations

Treat certain roots as **coordination-only** for attribution purposes.

Not a denylist, but a *class*:

* Roots that:

  * appear mostly in setup / registration functions
  * correlate with high fan-out hubs
  * rarely appear in leaf logic

When such a root wins salience:

* replace “shared ‘X’ context usage” with

  > “orchestration and integration logic”

This preserves correctness without false precision.

### Option B: qualify the wording

Keep the root name, but weaken the claim:

> “with cohesion influenced by shared keymap integration”

Still accurate, less misleading.

---

## Bottom line

* ✅ The message is **no longer wrong**
* ⚠️ It is **still slightly overconfident**
* 🛠️ One last explanatory refinement would make it genuinely sharp

Crucially:
**This is no longer a modeling failure.**
It’s about how fine-grained you want explanatory language to be.

If you want, next we can:

* formalize “coordination contexts” mechanically, or
* simply soften the wording when such roots dominate

Either way, you’re now operating in the last 10% of polish, not foundational correctness.
im thinking of reverting this whole browser refactor. 
analyze_lua_structure_v3.py
Python
please review this version of the tool we wrote here
I reverted the refactor. I don't care about that question any longer. Now what I care about is making the best tool I can to drive refactors going forward. It is with that in mind that I asked you to review this code. In particular, tell me if there's any backsliding here. Is there anything in your version that's been lost in this version and should be restored? 
ANALYSIS_TOOL_CLUSTER_TO_MODULE_SPEC v2.md
File
ANALYSIS_TOOL_OUTPUT_SENTENCE_STRUCTURE.md
File
Here is a spec and a conversation that I had since I've been talking to you. are they in alignment with my intent for the tool?
evaluate this output please
joe@joelap16 ui % ../../../scripts/analyze_lua_structure_v2.py project_browser.lua
CLUSTER 1
Type: Algorithm

InternalComponent of project_browser.lua.

Files:
project_browser.lua: 100%

Functions:
M.activate_selection
M.delete_selected_items
M.focus_bin
M.focus_master_clip
M.focus_sequence
M.insert_selected_to_timeline
M.refresh
M.select_all_items
M.start_inline_rename
activate_item
apply_single_selection
collect_all_tree_entries
create_bin_in_root
create_sequence_in_project
current_project_id
expand_bin_chain
generate_sequential_label
handle_command_event
is_descendant
lookup_item_by_tree_id
resolve_bin_parent
selection_context
sequence_defaults
set_bin_parent
show_browser_background_menu
start_inline_rename_after
update_selection_state

Analysis:
This cluster is organized around create_sequence_in_project, with cohesion driven by orchestration and coordination logic rather than a shared domain abstraction.
Most logic resides in project_browser.lua (100% of cluster LOC), indicating an existing structural center.
Fragile edges concentrate around create_bin_in_root, which is the lowest-structural-cost seam to peel responsibilities away from the cluster.
A first extraction candidate is the responsibility centered on create_bin_in_root; it touches the rest of the cluster mostly through weak ties, so it is a good candidate to separate and reattach with low risk.

Fragile edges: update_selection_state ↔ selection_context (0.69), M.focus_sequence ↔ selection_context (0.68), show_browser_background_menu ↔ apply_single_selection (0.66), M.focus_sequence ↔ M.activate_selection (0.65), create_bin_in_root ↔ M.refresh (0.64), create_sequence_in_project ↔ M.refresh (0.63), M.refresh ↔ lookup_item_by_tree_id (0.63), create_bin_in_root ↔ generate_sequential_label (0.62).

Boundary candidates: create_bin_in_root, create_sequence_in_project, M.refresh, start_inline_rename_after, update_selection_state.

CLUSTER 2
Type: Algorithm

InternalComponent of project_browser.lua.

Files:
project_browser.lua: 100%

Functions:
M.create
ensure_command_listener
finalize_pending_rename
handle_tree_editor_closed
handle_tree_item_changed
resolve_tree_item

Analysis:
This cluster is organized around M.create, with cohesion driven by orchestration and coordination logic rather than a shared domain abstraction.
Most logic resides in project_browser.lua (100% of cluster LOC), indicating an existing structural center.
Fragile edges concentrate around handle_tree_editor_closed, which is the lowest-structural-cost seam to peel responsibilities away from the cluster.
A first extraction candidate is the responsibility centered on handle_tree_editor_closed; it touches the rest of the cluster mostly through weak ties, so it is a good candidate to separate and reattach with low risk.

Fragile edges: handle_tree_editor_closed ↔ finalize_pending_rename (0.63), M.create ↔ ensure_command_listener (0.56).

Boundary candidates: handle_tree_editor_closed, finalize_pending_rename, M.create, ensure_command_listener.

CLUSTER 3
Type: Algorithm

InternalComponent of project_browser.lua.

Files:
project_browser.lua: 100%

Functions:
add_bin
add_master_clip_item
format_duration
get_bin_tag
store_tree_item

Analysis:
This cluster is organized around add_master_clip_item, with cohesion driven by orchestration and coordination logic rather than a shared domain abstraction.
Most logic resides in project_browser.lua (100% of cluster LOC), indicating an existing structural center.
Fragile edges concentrate around format_duration, which is the lowest-structural-cost seam to peel responsibilities away from the cluster.
A first extraction candidate is the responsibility centered on format_duration; it touches the rest of the cluster mostly through weak ties, so it is a good candidate to separate and reattach with low risk.

Fragile edges: add_bin ↔ format_duration (0.64), add_master_clip_item ↔ format_duration (0.62).

Boundary candidates: format_duration, add_bin, add_master_clip_item.

CLUSTER 4
Type: Algorithm

InternalComponent of project_browser.lua.

Files:
project_browser.lua: 100%

Functions:
clip_audio_channel_count
clip_has_audio

Analysis:
This cluster is organized around clip_has_audio, with cohesion driven by orchestration and coordination logic rather than a shared domain abstraction.
Most logic resides in project_browser.lua (100% of cluster LOC), indicating an existing structural center.

joe@joelap16 ui % 
i don't think the output is very good. i have low confidence in it. especially since it puts so many funcs in the first cluster and claims that create_sequence_in_project is the hub. how is that the hub when functions like M.activate_selection
M.delete_selected_items
M.focus_bin
M.focus_master_clip
M.focus_sequence
M.refresh
M.select_all_items
M.start_inline_rename
are in it? i think the cluster and the hub are nonsense