module asynchronous.libasync.events;

import std.algorithm;
import std.array;
import std.datetime;
import std.process;
import std.socket;
import std.stdio; // TODO remove this
import std.string;
import std.traits;
import std.typecons;
import libasync.events : EventLoop_ = EventLoop;
import libasync.timer : AsyncTimer;
import libasync.tcp : AsyncTCPConnection, NetworkAddress, TCPEvent;
import asynchronous.events;
import asynchronous.futures;
import asynchronous.protocols;
import asynchronous.tasks;
import asynchronous.transports;
import asynchronous.types;

alias Protocol = asynchronous.protocols.Protocol;

package class LibasyncEventLoop : EventLoop
{
    private EventLoop_ eventLoop;

    alias Timers = ResourcePool!(AsyncTimer, EventLoop_);
    private Timers timers;

    private Appender!(CallbackHandle[]) nextCallbacks1;
    private Appender!(CallbackHandle[]) nextCallbacks2;
    private Appender!(CallbackHandle[])* currentAppender;

    private LibasyncTcpTransport[] pendingConnections;

    this()
    {
        this.eventLoop = new EventLoop_;
        this.timers = new Timers(this.eventLoop);
        this.currentAppender = &nextCallbacks1;
    }

    override void runForever()
    {
        enforce(this.state == State.STOPPED,
                "Unexpected event loop state %s".format(this.state));

        this.state = State.RUNNING;

        while (true)
        {
            final switch (this.state)
            {
                case State.STOPPED:
                case State.STOPPING:
                    this.state = State.STOPPED;
                    return;
                case State.RUNNING:
                    auto callbacks = this.currentAppender;

                    if (this.currentAppender == &this.nextCallbacks1)
                        this.currentAppender = &this.nextCallbacks2;
                    else
                        this.currentAppender = &this.nextCallbacks1;

                    assert(this.currentAppender.data.empty);

                    if (callbacks.data.empty)
                    {
                        this.eventLoop.loop(0.seconds);
                    }
                    else
                    {
                        foreach (callback; callbacks.data)
                            callback();

                        callbacks.clear;
                    }
                    break;
                case State.CLOSED:
                    throw new Exception("Event loop closed while running.");
            }
        }
    }

    override void scheduleCallback(CallbackHandle callback)
    {
        currentAppender.put(callback);
    }

    override void scheduleCallback(Duration delay, CallbackHandle callback)
    {
        if (delay <= 0.seconds)
        {
            scheduleCallback(callback);
            return;
        }

        auto timer = this.timers.acquire();
        timer.duration(delay).run({
            callback();
            this.timers.release(timer);
        });
    }

    override void scheduleCallback(SysTime when, CallbackHandle callback)
    {
        Duration duration = when - time;

        scheduleCallback(duration, callback);
    }

    @Coroutine
    override void socketConnect(Socket socket, Address address)
    {
        auto asyncTCPConnection = new AsyncTCPConnection(this.eventLoop,
                                                         socket.handle);
        NetworkAddress peerAddress;

        (cast(byte*) peerAddress.sockAddr)[0 .. address.nameLen] =
            (cast(byte*) address.name)[0 .. address.nameLen];
        asyncTCPConnection.peer = peerAddress;

        auto connection = new LibasyncTcpTransport(this, socket,
                                                   asyncTCPConnection);

        asyncTCPConnection.run(&connection.handleTCPEvent);

        this.pendingConnections ~= connection;
    }

    override Transport makeSocketTransport(Socket socket, Protocol protocol,
                                           Future!void waiter)
    {
        auto index = this.pendingConnections.countUntil!(a => a.socket == socket);

        enforce(index >= 0, "Internal error");

        auto result = this.pendingConnections[index];

        if (this.pendingConnections.length > 1)
        {
            this.pendingConnections[index] = this.pendingConnections[$ - 1];
        }
        this.pendingConnections.length -= 1;

        result.setProtocol(protocol, waiter);

        return result;
    }

    @Coroutine
    override AddressInfo[] getAddressInfo(in char[] host, in char[] service,
            AddressFamily addressFamily = UNSPECIFIED!AddressFamily,
            SocketType socketType = UNSPECIFIED!SocketType,
            ProtocolType protocolType = UNSPECIFIED!ProtocolType,
            AddressInfoFlags addressInfoFlags = UNSPECIFIED!AddressInfoFlags)
    {
        // no async implementation in libasync yet, use the std.socket.getAddresInfo implementation;
        return std.socket.getAddressInfo(host, service, addressFamily,
                                         socketType, protocolType,
                                         addressInfoFlags);
    }

    version(Posix)
    {
        override void addSignalHandler(int sig, void delegate() handler)
        {
            assert(0, "addSignalHandler not implemented yet");
        }

        override void removeSignalHandler(int sig)
        {
            assert(0, "removeSignalHandler not implemented yet");
        }
    }

    //void setExceptionHandler(void function(EventLoop, ExceptionContext) handler)
    //{

    //}

    //void defaultExceptionHandler(ExceptionContext context)
    //{

    //}

    //void callExceptionHandler(ExceptionContext context)
    //{

    //}
}

class LibasyncEventLoopPolicy : EventLoopPolicy
{
    override EventLoop newEventLoop()
    {
        return new LibasyncEventLoop;
    }

    //version(Posix)
    //{
    //    override ChildWatcher getChildWatcher()
    //    {
    //        assert(0, "Not implemented");
    //    }

    //    override void setChildWatcher(ChildWatcher watcher)
    //    {
    //        assert(0, "Not implemented");
    //    }
    //}
}

private final class LibasyncTcpTransport : Transport
{
    private EventLoop eventLoop;
    private Socket _socket;
    private AsyncTCPConnection connection;
    private Future!void waiter;
    private Protocol protocol;
    private uint connectionLost = 0;
    private bool closing = false;
    private bool readingPaused = false;
    private bool writingPaused = false;
    private void[] writeBuffer;
    private BufferLimits writeBufferLimits;

    this(EventLoop eventLoop, Socket socket, AsyncTCPConnection connection)
    in
    {
        assert(eventLoop !is null);
        assert(socket !is null);
        assert(connection !is null);
        // assert(socket.handle == connection.socket);
    }
    body
    {
        this.eventLoop = eventLoop;
        this._socket = socket;
        this.connection = connection;
        this.waiter = waiter;
        setWriteBufferLimits;
    }

    @property
    Socket socket()
    {
        return this._socket;
    }

    void setProtocol(Protocol protocol, Future!void waiter = null)
    in
    {
        assert(protocol !is null);
        assert(this.protocol is null);
        assert(this.waiter is null);
    }
    body
    {
        this.protocol = protocol;
        this.waiter = waiter;
    }

    private void onConnect()
    in
    {
        assert(this.connection.isConnected);
        assert(this.protocol !is null);
    }
    body
    {
        this.eventLoop.callSoon(&this.protocol.connectionMade, this);

        if (this.waiter !is null)
            this.eventLoop.callSoon(&this.waiter.setResultUnlessCancelled);
    }

    private void onRead()
    in
    {
        assert(this.protocol !is null);
    }
    body
    {
        if (this.readingPaused)
            return;

        static ubyte[] buff = new ubyte[4092];
        auto len = this.connection.recv(buff);

        if (len)
        {
            this.eventLoop.callSoon(&this.protocol.dataReceived,
                                    buff[0 .. len]);
        }
        else
        {
            this.eventLoop.callSoon({
                if (!this.protocol.eofReceived)
                    close;
            });
        }
    }

    private void onWrite()
    in
    {
        assert(this.protocol !is null);
    }
    body
    {
        if (!this.writeBuffer.empty)
        {
            auto sent = this.connection.send(cast(ubyte[]) this.writeBuffer);
            this.writeBuffer = this.writeBuffer[sent .. $];
        }

        if (this.writingPaused &&
            this.writeBuffer.length <= this.writeBufferLimits.low)
        {
            this.protocol.resumeWriting;
            this.writingPaused = false;
        }
    }

    private void onClose()
    in
    {
        assert(this.protocol !is null);
    }
    body
    {
        this.eventLoop.callSoon(&this.protocol.connectionLost, null);
    }

    void handleTCPEvent(TCPEvent event)
    {
        final switch (event)
        {
            case TCPEvent.CONNECT:
                onConnect();
                break;
            case TCPEvent.READ:
                onRead();
                break;
            case TCPEvent.WRITE:
                onWrite();
                break;
            case TCPEvent.CLOSE:
                onClose();
                break;
            case TCPEvent.ERROR:
                assert(0, connection.error());
        }
    }


    /**
     * Transport interface
     */

    string getExtraInfo(string name)
    {
        assert(0, "Unknown transport information " ~ name);
    }

    void close()
    {
        if (this.closing)
            return;

        this.closing = true;
        this.eventLoop.callSoon(&this.connection.kill, false);
    }

    void pauseReading()
    {
        if (this.closing || this.connectionLost)
            throw new Exception("Cannot pauseReading() when closing");
        if (this.readingPaused)
            throw new Exception("Reading is already paused");

        this.readingPaused = true;
    }

    void resumeReading()
    {
        if (!this.readingPaused)
            throw new Exception("Reading is not paused");
        this.readingPaused = false;
    }

    void abort()
    {
        if (this.connectionLost)
            return;

        writeln("trying to abort the connection");
        this.eventLoop.callSoon(&this.connection.kill, true);
        ++this.connectionLost;
    }

    bool canWriteEof()
    {
        return true;
    }

    size_t getWriteBufferSize()
    {
        return writeBuffer.length;
    }

    BufferLimits getWriteBufferLimits()
    {
        return writeBufferLimits;
    }

    void setWriteBufferLimits(Nullable!size_t high = Nullable!size_t(),
                              Nullable!size_t low = Nullable!size_t())
    {
        if (high.isNull)
        {
            if (low.isNull)
                high = 64 * 1024;
            else
                high = 4 * low;
        }

        if (low.isNull)
            low = high / 4;

        if (high < low)
            low = high;

        this.writeBufferLimits.high = high;
        this.writeBufferLimits.low = low;
    }

    void write(const(void)[] data)
    in
    {
        assert(this.protocol !is null);
        assert(!this.writingPaused);
    }
    body
    {
        if (this.writeBuffer.empty)
        {
            auto sent = this.connection.send(cast(const ubyte[]) data);
            if (sent < data.length)
                this.writeBuffer = data[sent .. $].dup;
        }
        else
        {
            this.writeBuffer ~= data;
        }

        if (this.writeBuffer.length >= this.writeBufferLimits.high)
        {
            this.protocol.pauseWriting;
            this.writingPaused = true;
        }
    }

    void writeEof()
    {
        close;
    }
}
