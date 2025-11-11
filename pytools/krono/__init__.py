import time

def trace_enabled():
    return os.environ.get('KRONO_TRACE') == '1'

def now():
    return time.perf_counter()*1000
