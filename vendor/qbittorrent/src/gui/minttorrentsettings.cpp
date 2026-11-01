// Native desktop controls for the same runtime used by MintTorrent's WebUI.
#include "minttorrentsettings.h"

#include <QCheckBox>
#include <QFile>
#include <QFileDialog>
#include <QFormLayout>
#include <QJsonObject>
#include <QLabel>
#include <QListWidget>
#include <QMessageBox>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QSpinBox>
#include <QStackedWidget>
#include <QTimer>
#include <QVBoxLayout>

#include "base/minttorrentvpn.h"
#include "base/bittorrent/session.h"

using namespace Qt::Literals::StringLiterals;

void addMintTorrentSettings(QListWidget *selection, QStackedWidget *pages)
{
    auto *stackPage = new QWidget(pages);
    auto *stackLayout = new QVBoxLayout(stackPage);
    auto *description = new QLabel(QObject::tr("Torrent TCP, UDP and DNS use the in-process gVisor stack. Traffic stops when the VPN is unavailable. Incoming peers require port forwarding from your VPN provider; MintTorrent does not request or verify it."), stackPage);
    description->setWordWrap(true);
    stackLayout->addWidget(description);
    auto *form = new QFormLayout;
    stackLayout->addLayout(form);
    const auto state = MintTorrentVPN::status();
    auto *ipv4 = new QCheckBox(QObject::tr("Enabled"), stackPage);
    auto *ipv6 = new QCheckBox(QObject::tr("Enabled"), stackPage);
    ipv4->setChecked(state.value(u"ipv4"_s).toBool(true));
    ipv6->setChecked(state.value(u"ipv6"_s).toBool(true));
    form->addRow(QObject::tr("IPv4"), ipv4);
    form->addRow(QObject::tr("IPv6"), ipv6);
    auto spin = [form, stackPage, &state](const QString &label, const QString &key, int min, int max)
    {
        auto *box = new QSpinBox(stackPage);
        box->setRange(min, max);
        box->setValue(state.value(key).toInt());
        form->addRow(label, box);
        return box;
    };
    auto *mtu = spin(QObject::tr("MTU (0 = automatic)"), u"mtu"_s, 0, 9000);
    auto *queue = spin(QObject::tr("Packet queue"), u"packet_queue"_s, 64, 16384);
    auto *send = spin(QObject::tr("TCP send buffer (bytes)"), u"tcp_send_buffer"_s, 16384, 16777216);
    auto *receive = spin(QObject::tr("TCP receive buffer (bytes)"), u"tcp_receive_buffer"_s, 16384, 16777216);
    auto *apply = new QPushButton(QObject::tr("Apply settings and reconnect VPN"), stackPage);
    stackLayout->addWidget(apply);
    stackLayout->addStretch();
    selection->addItem(u"gVisor Netstack"_s);
    pages->addWidget(stackPage);

    auto *vpnPage = new QWidget(pages);
    auto *vpnLayout = new QVBoxLayout(vpnPage);
    auto *status = new QLabel(vpnPage);
    status->setWordWrap(true);
    vpnLayout->addWidget(status);
    auto *path = new QLabel(state.value(u"profile_path"_s).toString(), vpnPage);
    path->setWordWrap(true);
    path->setTextInteractionFlags(Qt::TextSelectableByMouse);
    vpnLayout->addWidget(path);
    auto *profile = new QPlainTextEdit(vpnPage);
    profile->setPlaceholderText(QObject::tr("Import or paste an AmneziaWG profile. Includes private keys; keep this page private."));
    profile->setPlainText(QString::fromUtf8(MintTorrentVPN::savedProfile()));
    vpnLayout->addWidget(profile);
    auto *load = new QPushButton(QObject::tr("Import profile from file…"), vpnPage);
    auto *connectVPN = new QPushButton(QObject::tr("Save profile and connect"), vpnPage);
    auto *disconnectVPN = new QPushButton(QObject::tr("Disconnect VPN"), vpnPage);
    vpnLayout->addWidget(load);
    vpnLayout->addWidget(connectVPN);
    vpnLayout->addWidget(disconnectVPN);
    selection->addItem(u"AmneziaWG"_s);
    pages->addWidget(vpnPage);

    auto refresh = [status]
    {
        const auto s = MintTorrentVPN::status();
        const QString text = !s.value(u"active"_s).toBool() ? QObject::tr("VPN disconnected — torrent traffic blocked")
            : s.value(u"data_path_healthy"_s).toBool() ? QObject::tr("VPN connected — data path healthy")
            : QObject::tr("VPN connecting / data path unavailable: %1").arg(s.value(u"health_error"_s).toString());
        status->setText(text);
    };
    auto *timer = new QTimer(vpnPage);
    QObject::connect(timer, &QTimer::timeout, vpnPage, refresh);
    timer->start(2000);
    refresh();
    QObject::connect(load, &QPushButton::clicked, vpnPage, [vpnPage, profile]
    {
        const QString name = QFileDialog::getOpenFileName(vpnPage, QObject::tr("Import AmneziaWG profile"), {}, QObject::tr("VPN profiles (*.conf);;All files (*)"));
        if (name.isEmpty())
            return;
        QFile file(name);
        if (!file.open(QIODevice::ReadOnly) || file.size() <= 0 || file.size() > 128 * 1024)
        {
            QMessageBox::warning(vpnPage, u"AmneziaWG"_s, QObject::tr("Cannot read profile, or its size is outside 1–131072 bytes."));
            return;
        }
        profile->setPlainText(QString::fromUtf8(file.readAll()));
    });
    auto save = [=]
    {
        QString error;
        if (!MintTorrentVPN::importAndStart(profile->toPlainText().toUtf8(), ipv4->isChecked(), ipv6->isChecked(), mtu->value(), queue->value(), send->value(), receive->value(), &error))
            QMessageBox::warning(pages, u"AmneziaWG"_s, error);
        BitTorrent::Session::instance()->refreshNetworkInterfaces();
        refresh();
    };
    QObject::connect(apply, &QPushButton::clicked, stackPage, save);
    QObject::connect(connectVPN, &QPushButton::clicked, vpnPage, save);
    QObject::connect(disconnectVPN, &QPushButton::clicked, vpnPage, [=]
    {
        QString error;
        if (!MintTorrentVPN::setEnabled(false, &error))
            QMessageBox::warning(pages, u"AmneziaWG"_s, error);
        BitTorrent::Session::instance()->refreshNetworkInterfaces();
        refresh();
    });
}
