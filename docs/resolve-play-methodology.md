why is my pipeline currently slower than resolve?                       
                                                                                                                         
⏺ Let me look at your actual playback pipeline to identify bottlenecks:                                                  
                                                                                                                         
⏺ Searched for 4 patterns, read 4 files (ctrl+o to expand)                                                               
                                                                                                                         
⏺ Now I see the pipeline. Here are the likely bottlenecks:                                                               
                                                                                                                         
  ★ Insight ─────────────────────────────────────                                                                        
  Your tick loop runs in Lua with single-shot QTimers:                                                                   
  QTimer fires (16-41ms) → Lua _tick() → C++ TMB decode → Lua callback → C++ Metal display                               
          ↑                     ↑              ↑                              ↑                                          
      timer jitter        FFI boundary    may block           FFI boundary again                                         
                                                                                                                         
  Resolve's loop is likely VSync-driven:                                                                                 
  CVDisplayLink fires → C++ decode → GPU display                                                                         
       ↑ hardware-precise, no scripting in hot path                                                                      
  ─────────────────────────────────────────────────                                                                      
                                                                                                                         
  Specific Bottlenecks                                                                                                   
  ┌────────────────────────┬─────────────────────────┬────────────────────────────────────────────┐                      
  │         Issue          │         Impact          │                  Location                  │                      
  ├────────────────────────┼─────────────────────────┼────────────────────────────────────────────┤                      
  │ Timer-per-frame        │ Jitter, GC pauses       │ _schedule_tick() creates QTimer each frame │                      
  ├────────────────────────┼─────────────────────────┼────────────────────────────────────────────┤                      
  │ Lua in hot path        │ FFI overhead 24-60x/sec │ _tick() is Lua, calls C++ TMB, back to Lua │                      
  ├────────────────────────┼─────────────────────────┼────────────────────────────────────────────┤                      
  │ No VSync sync          │ Tearing, frame drops    │ Timer interval != display refresh          │                      
  ├────────────────────────┼─────────────────────────┼────────────────────────────────────────────┤                      
  │ Audio-check every tick │ Unnecessary work        │ _try_audio() runs per frame                │                      
  └────────────────────────┴─────────────────────────┴────────────────────────────────────────────┘                      
  What Resolve Does Differently                                                                                          
                                                                                                                         
  1. CVDisplayLink (macOS): Hardware callback at exact VSync intervals. No timer jitter.                                 
  2. C++ hot path: Frame fetch → display is entirely C++. No scripting language.                                         
  3. GPU-driven frame pacing: Display owns the cadence; decode catches up.                                               
  4. Triple buffering: Decode-ahead hides latency.                                                                       
                                                                                                                         
  Quick Wins (No Architecture Change)                                                                                    
                                                                                                                         
  1. Move tick to C++: One persistent timer in C++, callbacks to Lua only when clip changes or position notification     
  needed.                                                                                                                
  2. CVDisplayLink for display: Let GPU request frames at VSync, not timer-driven.                                       
  3. Batch Lua callbacks: Position updates can coalesce; don't need per-frame.                                           
                                                                                                                         
  Bigger Win                                                                                                             
                                                                                                                         
  Make TMB own the playback loop entirely:                                                                               
  Lua: TMB_PLAY(direction, speed)                                                                                        
  C++: CVDisplayLink → TMB::GetFrame() → Metal display                                                                   
       (Lua gets position updates via signal, not per-tick call)                                                         
                                                                                                                         
  This removes Lua from the hot path completely. Lua handles transport commands, C++ handles frame delivery.             
                                                                                                                         
  ---                                                                                                                    
  Want me to prototype the CVDisplayLink + C++ tick approach? It's a meaningful refactor but would get you to            
  Resolve-level smoothness.
