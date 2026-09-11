// Prints one line and instantiates the QML scene. The line is what the size
// check greps for: an image that links but cannot run its own QML is not proof
// that the Qt build is usable.
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QRemoteObjectNode>
#include <QtGlobal>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    qInfo("logos-qt-wasm-probe: Qt %s", qVersion());

    // Touched so the QtRO replica side is linked in rather than dropped by the
    // linker: the runtime reaches a module's backend through a node like this.
    QRemoteObjectNode node;
    Q_UNUSED(node)

    QQmlApplicationEngine engine;
    engine.loadFromModule("LogosWasmProbe", "Main");
    if (engine.rootObjects().isEmpty())
        return 1;
    return app.exec();
}
