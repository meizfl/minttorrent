// Test-only preload helper: inspect a real offscreen Qt desktop instance.
#include <QAction>
#include <QApplication>
#include <QCheckBox>
#include <QFile>
#include <QLabel>
#include <QListWidget>
#include <QPushButton>
#include <QPalette>
#include <QTimer>
#include <QWidget>

static void captureSettings()
{
    const QString output = qEnvironmentVariable("MINTTORRENT_GUI_PROBE_DIR");
    if (output.isEmpty())
        return;
    QTimer::singleShot(1200, qApp, [output]
    {
        QWidget *main = nullptr;
        for (auto *widget : QApplication::topLevelWidgets())
            if (widget->objectName() == QStringLiteral("MainWindow")) main = widget;
        if (!main) { qApp->exit(41); return; }
        if (!main->windowTitle().startsWith(QStringLiteral("MintTorrent"))) { qApp->exit(46); return; }
        const auto accent = qApp->palette().color(QPalette::Highlight);
        if (accent.green() <= accent.blue() || accent.green() <= accent.red()) { qApp->exit(47); return; }
        if (auto *about = main->findChild<QAction *>(QStringLiteral("actionAbout")))
        {
            about->trigger();
            QApplication::processEvents();
            for (auto *widget : QApplication::topLevelWidgets())
                if (widget->objectName() == QStringLiteral("AboutDialog"))
                {
                    widget->grab().save(output + QStringLiteral("/about.png"));
                    widget->close();
                }
        }
        main->grab().save(output + QStringLiteral("/main.png"));
        auto *action = main->findChild<QAction *>(QStringLiteral("actionOptions"));
        if (!action) { qApp->exit(42); return; }
        action->trigger();
        QTimer::singleShot(500, qApp, [output]
        {
            QWidget *options = nullptr;
            for (auto *widget : QApplication::topLevelWidgets())
                if (widget->objectName() == QStringLiteral("OptionsDialog")) options = widget;
            if (!options) { qApp->exit(43); return; }
            auto *list = options->findChild<QListWidget *>(QStringLiteral("tabSelection"));
            if (!list) { qApp->exit(44); return; }
            int found = 0;
            for (int i = 0; i < list->count(); ++i)
            {
                const auto text = list->item(i)->text();
                if (text != QStringLiteral("gVisor Netstack") && text != QStringLiteral("AmneziaWG")) continue;
                list->setCurrentRow(i);
                QApplication::processEvents();
                options->grab().save(output + (text == QStringLiteral("AmneziaWG") ? QStringLiteral("/vpn.png") : QStringLiteral("/netstack.png")));
                ++found;
            }
            QFile result(output + QStringLiteral("/result.txt"));
            if (!result.open(QIODevice::WriteOnly)) { qApp->exit(48); return; }
            result.write(found == 2 ? "PASS: MintTorrent window, green accent, About and both settings pages rendered\n" : "FAIL: settings pages missing\n");
            result.close();
            qApp->exit(found == 2 ? 0 : 45);
        });
    });
}
Q_COREAPP_STARTUP_FUNCTION(captureSettings)
