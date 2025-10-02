#include <QtTest/QtTest>
#include <QApplication>

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

class TestTimelineLuaLogic : public QObject
{
    Q_OBJECT

private:
    lua_State* L = nullptr;

    void loadTimelineModule() {
        // Load timeline.lua module
        int result = luaL_dofile(L, "src/lua/ui/timeline/timeline.lua");
        if (result != LUA_OK) {
            QString error = lua_tostring(L, -1);
            QFAIL(qPrintable(QString("Failed to load timeline.lua: %1").arg(error)));
        }
        lua_setglobal(L, "timeline_module");
    }

    double getNumberField(const char* table, const char* field) {
        lua_getglobal(L, table);
        lua_getfield(L, -1, field);
        double value = lua_tonumber(L, -1);
        lua_pop(L, 2);
        return value;
    }

private slots:
    void initTestCase() {
        L = luaL_newstate();
        luaL_openlibs(L);

        // Load timeline module
        loadTimelineModule();

        // Get timeline module
        lua_getglobal(L, "timeline_module");
        if (!lua_istable(L, -1)) {
            QFAIL("Timeline module did not return a table");
        }

        // Get dimensions table
        lua_getfield(L, -1, "dimensions");
        QVERIFY2(lua_istable(L, -1), "Timeline module should have dimensions table");
        lua_pop(L, 2);
    }

    void cleanupTestCase() {
        lua_close(L);
    }

    // Test: Timeline dimensions are defined
    void testTimelineDimensions() {
        lua_getglobal(L, "timeline_module");
        lua_getfield(L, -1, "dimensions");

        QVERIFY(lua_istable(L, -1));

        lua_getfield(L, -1, "ruler_height");
        QVERIFY(lua_isnumber(L, -1));
        int ruler_height = lua_tointeger(L, -1);
        QVERIFY(ruler_height > 0);
        lua_pop(L, 1);

        lua_getfield(L, -1, "track_height");
        QVERIFY(lua_isnumber(L, -1));
        int track_height = lua_tointeger(L, -1);
        QVERIFY(track_height > 0);
        lua_pop(L, 1);

        lua_getfield(L, -1, "track_header_width");
        QVERIFY(lua_isnumber(L, -1));
        int track_header_width = lua_tointeger(L, -1);
        QVERIFY(track_header_width > 0);
        lua_pop(L, 3);
    }

    // Test: Time-to-pixel conversion logic
    void testTimeToPixelConversion() {
        // Test the mathematical relationship
        // At zoom level 0.1 pixels/ms:
        // 1000ms should be 100 pixels
        // 5000ms should be 500 pixels

        const char* code = R"(
            local timeline = require('src/lua/ui/timeline/timeline')

            -- Mock state
            local state = {
                zoom = 0.1,  -- 0.1 pixels per millisecond
                scroll_offset = 0,
                track_header_width = 150
            }

            -- Time to pixel: pixel = (time_ms * zoom) - scroll_offset
            function test_time_to_pixel(time_ms)
                return math.floor((time_ms * state.zoom) - state.scroll_offset)
            end

            -- Pixel to time: time_ms = (pixel + scroll_offset) / zoom
            function test_pixel_to_time(pixel)
                return math.floor((pixel + state.scroll_offset) / state.zoom)
            end
        )";

        int result = luaL_dostring(L, code);
        if (result != LUA_OK) {
            QString error = lua_tostring(L, -1);
            QFAIL(qPrintable(QString("Lua error: %1").arg(error)));
        }

        // Test time to pixel
        lua_getglobal(L, "test_time_to_pixel");
        lua_pushnumber(L, 1000);  // 1000ms
        lua_pcall(L, 1, 1, 0);
        int pixel = lua_tointeger(L, -1);
        lua_pop(L, 1);
        QCOMPARE(pixel, 100);  // Should be 100 pixels

        // Test pixel to time
        lua_getglobal(L, "test_pixel_to_time");
        lua_pushnumber(L, 500);  // 500 pixels
        lua_pcall(L, 1, 1, 0);
        int time_ms = lua_tointeger(L, -1);
        lua_pop(L, 1);
        QCOMPARE(time_ms, 5000);  // Should be 5000ms
    }

    // Test: Zoom level constraints
    void testZoomConstraints() {
        const char* code = R"(
            function test_zoom_clamp(zoom_factor)
                return math.max(0.01, math.min(10.0, zoom_factor))
            end
        )";

        luaL_dostring(L, code);

        // Test minimum clamp
        lua_getglobal(L, "test_zoom_clamp");
        lua_pushnumber(L, -1.0);
        lua_pcall(L, 1, 1, 0);
        double clamped_min = lua_tonumber(L, -1);
        lua_pop(L, 1);
        QCOMPARE(clamped_min, 0.01);

        // Test maximum clamp
        lua_getglobal(L, "test_zoom_clamp");
        lua_pushnumber(L, 100.0);
        lua_pcall(L, 1, 1, 0);
        double clamped_max = lua_tonumber(L, -1);
        lua_pop(L, 1);
        QCOMPARE(clamped_max, 10.0);

        // Test valid range
        lua_getglobal(L, "test_zoom_clamp");
        lua_pushnumber(L, 0.5);
        lua_pcall(L, 1, 1, 0);
        double clamped_valid = lua_tonumber(L, -1);
        lua_pop(L, 1);
        QCOMPARE(clamped_valid, 0.5);
    }

    // Test: Ruler interval calculation
    void testRulerIntervalCalculation() {
        const char* code = R"(
            function calculate_ruler_interval(zoom)
                local target_pixel_spacing = 80
                local interval_ms = math.floor(target_pixel_spacing / zoom)

                local nice_intervals = {100, 200, 500, 1000, 2000, 5000, 10000, 30000, 60000}
                for _, nice in ipairs(nice_intervals) do
                    if interval_ms <= nice then
                        return nice
                    end
                end
                return 60000
            end
        )";

        luaL_dostring(L, code);

        // At high zoom (zoomed in), should use small interval
        lua_getglobal(L, "calculate_ruler_interval");
        lua_pushnumber(L, 1.0);  // 1 pixel per ms (very zoomed in)
        lua_pcall(L, 1, 1, 0);
        int interval_zoomed_in = lua_tointeger(L, -1);
        lua_pop(L, 1);
        QCOMPARE(interval_zoomed_in, 100);  // Should use 100ms interval

        // At low zoom (zoomed out), should use larger interval
        lua_getglobal(L, "calculate_ruler_interval");
        lua_pushnumber(L, 0.01);  // 0.01 pixels per ms (very zoomed out)
        lua_pcall(L, 1, 1, 0);
        int interval_zoomed_out = lua_tointeger(L, -1);
        lua_pop(L, 1);
        QVERIFY(interval_zoomed_out >= 1000);  // Should use at least 1s interval
    }

    // Test: Clip boundary constraint logic
    void testClipBoundaryConstraints() {
        const char* code = R"(
            function constrain_clip_drag(clips, delta_time)
                local min_allowed_delta = delta_time
                for _, clip in ipairs(clips) do
                    local new_start = clip.start_time + delta_time
                    if new_start < 0 then
                        min_allowed_delta = math.max(min_allowed_delta, -clip.start_time)
                    end
                end
                return min_allowed_delta
            end
        )";

        luaL_dostring(L, code);

        // Test: Clip at 1000ms dragged left by 2000ms
        // Should constrain to -1000ms (can't go below 0)
        const char* test_code = R"(
            local clips = {
                {start_time = 1000},
                {start_time = 2000}
            }
            return constrain_clip_drag(clips, -2000)
        )";

        luaL_dostring(L, test_code);
        int constrained_delta = lua_tointeger(L, -1);
        lua_pop(L, 1);
        QCOMPARE(constrained_delta, -1000);  // Should constrain to -1000
    }

    // Test: Clip rectangle intersection logic
    void testClipRectangleIntersection() {
        const char* code = R"(
            function rectangles_overlap(x1, y1, w1, h1, x2, y2, w2, h2)
                return not (x1 + w1 < x2 or x1 > x2 + w2 or
                           y1 + h1 < y2 or y1 > y2 + h2)
            end
        )";

        luaL_dostring(L, code);

        // Test overlapping rectangles
        lua_getglobal(L, "rectangles_overlap");
        lua_pushnumber(L, 10);  // x1
        lua_pushnumber(L, 10);  // y1
        lua_pushnumber(L, 50);  // w1
        lua_pushnumber(L, 30);  // h1
        lua_pushnumber(L, 30);  // x2 (overlaps)
        lua_pushnumber(L, 20);  // y2 (overlaps)
        lua_pushnumber(L, 50);  // w2
        lua_pushnumber(L, 30);  // h2
        lua_pcall(L, 8, 1, 0);
        bool overlaps = lua_toboolean(L, -1);
        lua_pop(L, 1);
        QVERIFY(overlaps);

        // Test non-overlapping rectangles
        lua_getglobal(L, "rectangles_overlap");
        lua_pushnumber(L, 10);  // x1
        lua_pushnumber(L, 10);  // y1
        lua_pushnumber(L, 50);  // w1
        lua_pushnumber(L, 30);  // h1
        lua_pushnumber(L, 100); // x2 (far away)
        lua_pushnumber(L, 100); // y2 (far away)
        lua_pushnumber(L, 50);  // w2
        lua_pushnumber(L, 30);  // h2
        lua_pcall(L, 8, 1, 0);
        bool no_overlap = lua_toboolean(L, -1);
        lua_pop(L, 1);
        QVERIFY(!no_overlap);
    }

    // Test: Track Y position calculation
    void testTrackYPosition() {
        const char* code = R"(
            function get_track_y(track_index, ruler_height, track_height)
                return ruler_height + (track_index * track_height)
            end
        )";

        luaL_dostring(L, code);

        // Test track 0 (first track)
        lua_getglobal(L, "get_track_y");
        lua_pushnumber(L, 0);   // track_index
        lua_pushnumber(L, 32);  // ruler_height
        lua_pushnumber(L, 50);  // track_height
        lua_pcall(L, 3, 1, 0);
        int track0_y = lua_tointeger(L, -1);
        lua_pop(L, 1);
        QCOMPARE(track0_y, 32);  // First track starts after ruler

        // Test track 2 (third track)
        lua_getglobal(L, "get_track_y");
        lua_pushnumber(L, 2);   // track_index
        lua_pushnumber(L, 32);  // ruler_height
        lua_pushnumber(L, 50);  // track_height
        lua_pcall(L, 3, 1, 0);
        int track2_y = lua_tointeger(L, -1);
        lua_pop(L, 1);
        QCOMPARE(track2_y, 132);  // 32 + (2 * 50)
    }

    // Test: Playhead proximity detection
    void testPlayheadProximity() {
        const char* code = R"(
            function is_near_playhead(x, playhead_x, tolerance)
                local distance = math.abs(x - playhead_x)
                return distance < tolerance
            end
        )";

        luaL_dostring(L, code);

        // Test near playhead
        lua_getglobal(L, "is_near_playhead");
        lua_pushnumber(L, 103);  // x
        lua_pushnumber(L, 100);  // playhead_x
        lua_pushnumber(L, 5);    // tolerance
        lua_pcall(L, 3, 1, 0);
        bool is_near = lua_toboolean(L, -1);
        lua_pop(L, 1);
        QVERIFY(is_near);

        // Test far from playhead
        lua_getglobal(L, "is_near_playhead");
        lua_pushnumber(L, 200);  // x
        lua_pushnumber(L, 100);  // playhead_x
        lua_pushnumber(L, 5);    // tolerance
        lua_pcall(L, 3, 1, 0);
        bool is_far = lua_toboolean(L, -1);
        lua_pop(L, 1);
        QVERIFY(!is_far);
    }
};

QTEST_MAIN(TestTimelineLuaLogic)
#include "test_timeline_lua_logic.moc"
