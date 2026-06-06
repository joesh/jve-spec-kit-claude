#!/usr/bin/env python3
"""Probe Resolve's color science / output transform settings.

Background: spec 023 Piece 3 (LUT3D renderer stage) is structurally
correct (identity LUT == ungraded passthrough) and the YUV→RGB path
is correct (sv44 = video-range, confirmed 2026-06-05 by force-routing
to full-range — JVE then overshot Resolve). The residual gap (JVE
darker + green vs Resolve preview on Anamnesis) must therefore live
in something Resolve applies that ExportLUT does NOT capture: a
project/timeline-level output transform, IDT/ODT, working-color-space,
display LUT, or color-management mode.

This spike enumerates the relevant Project + Timeline settings on the
currently-open Resolve project so we have evidence for spec 024 (proper
color management) instead of guessing.

Run while Resolve Studio is open with the Anamnesis project loaded:
    python3 tools/resolve-helper/spikes/t033c_probe_color_settings.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from resolve_handle import ResolveHandle  # noqa: E402


# Settings keys believed to bear on the JVE-vs-Resolve color gap. Some
# are project-scoped, some timeline-scoped (Resolve overlaps the
# namespaces in a few places). GetSetting returns "" for unknown keys
# rather than raising, so an empty value means "not set / not
# applicable for this color science mode" — still informative.
PROJECT_SETTING_KEYS = [
    # The big one — determines whether ExportLUT captures the whole
    # display transform or only a partial slice of it.
    "colorScienceMode",
    # ACES path inputs/outputs (relevant only if mode includes ACES).
    "colorAcesIDT",
    "colorAcesODT",
    "colorAcesNodeLUTProcessing",
    "colorAcesGamutCompressType",
    "colorAcesVersion",
    # DaVinci-YRGB-Color-Managed inputs/outputs.
    "colorSpaceInput",
    "colorSpaceInputGamma",
    "colorSpaceTimeline",
    "colorSpaceOutput",
    "colorSpaceOutputGamma",
    # Output transforms / DRT.
    "inputDRT",
    "outputDRT",
    # Tone mapping / gamut mapping.
    "hdrMasteringLuminanceMax",
    "hdrMasteringOn",
    "hdrToneMapping",
    "gamutMappingMode",
    # Misc that show up in some color modes.
    "useColorSpaceAwareGradingTools",
    "separateColorSpaceAndGamma",
    # Working space / luminance scale.
    "workingLuminance",
    "workingLuminanceMode",
    # Monitor / display LUTs — the classic "preview vs ExportLUT" gap
    # in vanilla davinciYRGB. These apply AFTER the node graph on the
    # preview output but are NOT captured by TimelineItem.ExportLUT.
    "videoMonitorLUT",
    "videoMonitor3DLUT",
    "videoMonitorScalingMode",
    "monitorLUTBypass",
    "colorVersion10Name",
    # Display-side LUT processing flags.
    "use1DOutputLUT",
    "useColorVersionAware",
    "videoDataLevels",
    "videoDataLevelsRetainSubBlackAndSuperWhite",
    # 2026-06-05: HDR1000 timeline working luminance with YRGB project
    # mode is a real combo — probe how the SDR display gets the timeline.
    "videoMonitorBitDepth",
    "videoMonitorFormat",
]

# System-level / user-preference keys probed on the top-level `resolve`
# object (not project, not timeline). The big one Joe recalls:
# "Use Mac Display Color Profiles for viewers" lives here, NOT in the
# project. Affects whether Resolve converts Rec.709 → Mac ColorSync
# display profile before drawing the viewer (the macOS preview window,
# not the SDI/Decklink monitor output).
SYSTEM_SETTING_KEYS = [
    "UseMacDisplayColorProfilesForViewers",
    "useMacDisplayColorProfilesForViewers",
    "UseColorAwareViewerDisplay",
    "useColorAwareViewerDisplay",
    "UiDisplayMode",
    "ViewerGamma",
    "ViewerColorSpace",
    "MacDisplayColorProfile",
    "ColorAccurateViewer",
    "viewerExtendedRange",
]


TIMELINE_SETTING_KEYS = [
    "timelineFrameRate",
    "timelineResolutionWidth",
    "timelineResolutionHeight",
    # The timeline-level color-science overrides. Important: a timeline
    # can override the project's colorScienceMode in modern Resolve.
    "timelineColorSpace",
    "timelineWorkingLuminance",
    "timelineWorkingLuminanceMode",
    "timelineOutputColorSpace",
    "timelineInputColorSpace",
    "useColorSpaceAwareGradingTools",
]


def main():
    handle = ResolveHandle()
    status = handle.acquire()
    if status[0] != "ok":
        sys.stderr.write(f"acquire failed: {status}\n")
        sys.exit(1)
    _, resolve, project = status

    try:
        product = resolve.GetProductName()
        version = resolve.GetVersionString()
    except Exception as exc:
        product = f"<GetProductName raised: {exc}>"
        version = "?"

    try:
        project_name = project.GetName()
    except Exception as exc:
        project_name = f"<GetName raised: {exc}>"

    timeline = None
    timeline_name = None
    try:
        timeline = project.GetCurrentTimeline()
        if timeline:
            timeline_name = timeline.GetName()
    except Exception as exc:
        timeline_name = f"<GetCurrentTimeline raised: {exc}>"

    def get_setting(obj, key):
        try:
            v = obj.GetSetting(key)
        except Exception as exc:
            return f"<raised: {exc}>"
        return v

    project_settings = {k: get_setting(project, k) for k in PROJECT_SETTING_KEYS}
    timeline_settings = (
        {k: get_setting(timeline, k) for k in TIMELINE_SETTING_KEYS}
        if timeline is not None
        else None
    )
    system_settings = {k: get_setting(resolve, k) for k in SYSTEM_SETTING_KEYS}

    out = {
        "resolve_product": product,
        "resolve_version": version,
        "project_name": project_name,
        "timeline_name": timeline_name,
        "system_settings": system_settings,
        "project_settings": project_settings,
        "timeline_settings": timeline_settings,
    }

    print(json.dumps(out, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
