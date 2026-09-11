// The link's reason to pull in the whole runtime: a QML engine loading a
// document, plus a QtRO node. Nothing here runs during the build — a Qt-wasm
// image needs a canvas — so what the probe proves is that this translation unit
// LINKS against the wasm Qt next door, and what the resulting image WEIGHS
// (../qml-probe.nix).
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
