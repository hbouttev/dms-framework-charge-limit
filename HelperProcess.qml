import QtQuick
import Quickshell.Io

// Runs one command and reports its exit code, stdout and stderr together, once all three
// are available (Process.exited can arrive before the output streams are drained).
Process {
    id: proc

    signal finished(int exitCode, string out, string err)

    property bool _exited: false
    property bool _outDone: false
    property bool _errDone: false
    property int _exitCode: -1
    property bool _reported: true

    function start(argv) {
        if (running || !_reported)
            return false;
        command = argv;
        _exited = false;
        _outDone = false;
        _errDone = false;
        _exitCode = -1;
        _reported = false;
        running = true;
        return true;
    }

    // Stops the command and reports `exitCode` without waiting for it (watchdog).
    function abandon(exitCode) {
        if (_reported)
            return;
        _reported = true;
        running = false;
        finished(exitCode, outCollector.text || "", errCollector.text || "");
    }

    function _maybeReport() {
        if (_reported || !_exited || !_outDone || !_errDone)
            return;
        _reported = true;
        finished(_exitCode, outCollector.text || "", errCollector.text || "");
    }

    stdout: StdioCollector {
        id: outCollector
        onStreamFinished: {
            proc._outDone = true;
            proc._maybeReport();
        }
    }

    stderr: StdioCollector {
        id: errCollector
        onStreamFinished: {
            proc._errDone = true;
            proc._maybeReport();
        }
    }

    onExited: (exitCode, exitStatus) => {
        _exitCode = exitCode;
        _exited = true;
        _maybeReport();
    }
}
