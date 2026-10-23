#pragma once

#include <QString>
#include <QStringList>

namespace home_rows
{
/// A titled row of movies as the media ids it holds, best first and not yet
/// cut to the cards Home draws. Rows built from the profile's taste, the
/// season and the shuffle keep ids, not copies of the items, so the cards are
/// always read from the current items when Home composes.
struct IdRow
{
    QString id;
    QString title;
    QStringList mediaIds;
};
}
