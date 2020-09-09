module dls.util.debounce;

private {
    import std.traits : ParameterTypeTuple, isCallable;
    import std.string : format;
    import core.time : Duration;
    import core.sync.mutex : Mutex;
    import core.sync.condition : Condition;
    import core.sync.exception : SyncError;

    import std.stdio : stderr;
}

public import core.thread;

class TTimer(T...) : Thread {
    static assert(T.length <= 1);
    static if(T.length == 1) {
        static assert(isCallable!(T[0]));
        alias  Args = ParameterTypeTuple!(T[0]);
    } else {
        alias Args = T;
    }

    protected Duration interval;
    protected Args args;
    protected void delegate(Args) func;

    protected Event finished;
    @property bool is_finished() { return finished.is_set; }

    this(Duration interval, void delegate(Args) func, Args args) {
        super(&run);

        finished = new Event();

        this.interval = interval;
        this.func = func;

        static if(Args.length) {
            this.args = args;
        }
    }

    final
    void cancel() {
        finished.set();
    }

    protected
    void run() {
        finished.wait(interval);

        if(!finished.is_set) {
            func(args);
        }

        finished.set();
    }

}

alias Timer = TTimer!();


class Event {
    protected Mutex mutex;
    protected Condition cond;

    protected bool flag;
    @property bool is_set() { return flag; }

    this() {
        mutex = new Mutex();
        cond = new Condition(mutex);

        flag = false;
    }

    void set() {
        mutex.lock();
        scope(exit) mutex.unlock();

        flag = true;
        cond.notifyAll();
    }

    void clear() {
        mutex.lock();
        scope(exit) mutex.unlock();

        flag = false;
    }

    bool wait(T...)(T timeout) if(T.length == 0 || (T.length == 1 && is(T[0] : Duration))) {
        mutex.lock();
        scope(exit) mutex.unlock();

        bool notified = flag;
        if(!notified) {
            static if(T.length == 0) {
                cond.wait();
                notified = true;
            } else {
                notified = cond.wait(timeout);
            }
        }
        return notified;
    }
}

auto debounce (T...) (void delegate (T) expr, Duration duration, bool immediate = false) {
    Timer timeout;
    return delegate (T args) {
        void delegate () later = {
            timeout.cancel ();
            if (!immediate) {
                expr (args);
            }
        };
        auto callNow = immediate && timeout !is null;

        if (timeout !is null)
            timeout.cancel ();

        timeout = new Timer (duration, later);
        timeout.start ();

        if (callNow) {
            expr (args);
        }
    };
}
