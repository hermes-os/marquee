#include "support/FileIdentity.hpp"

#include <QFile>

#include <sys/stat.h>

std::optional<FileIdentity> readFileIdentity(const QString &path)
{
    struct stat status{};
    if (::stat(QFile::encodeName(path).constData(), &status) != 0) {
        return std::nullopt;
    }
    return FileIdentity{.device = static_cast<quint64>(status.st_dev),
                        .inode = static_cast<quint64>(status.st_ino)};
}
