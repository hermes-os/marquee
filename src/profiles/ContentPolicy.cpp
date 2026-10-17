#include "profiles/ContentPolicy.hpp"

#include <QChar>
#include <QHash>
#include <QLatin1Char>
#include <QRegularExpression>
#include <QSet>

#include <algorithm>
#include <iterator>

#include "profiles/ProfileStore.hpp"

namespace content_policy
{
namespace
{
// CatalogContentPolicy.swift:506-524: the year suffix and possessives go, every
// other non-alphanumeric run becomes one space, and the result is lowercased.
[[nodiscard]] QString offlineLookupKey(const QString &title)
{
    static const QRegularExpression yearSuffix(QStringLiteral(R"(\s*\(\d{4}\)\s*$)"));
    static const QRegularExpression possessive(QStringLiteral(R"(['\x{2019}])"));
    QString key = title;
    key.remove(yearSuffix);
    key.remove(possessive);
    QString folded;
    folded.reserve(key.size());
    for (const QChar character : key) {
        folded.append(character.isLetterOrNumber() ? character : QLatin1Char(' '));
    }
    return folded.toLower().simplified();
}

// CatalogContentPolicy.swift:400-476: title fragments that mark a movie's
// genre. Matched as substrings of the normalized title, as the released
// `containsAny` does.
[[nodiscard]] bool containsAny(const QString &key, const QStringList &fragments)
{
    return std::any_of(fragments.cbegin(), fragments.cend(),
                       [&key](const QString &fragment) { return key.contains(fragment); });
}
}

QStringList uniqueGenres(const QStringList &genres)
{
    QSet<QString> seen;
    QStringList result;
    for (const QString &raw : genres) {
        const QString genre = raw.trimmed();
        if (genre.isEmpty() || seen.contains(genre.toLower())) {
            continue;
        }
        seen.insert(genre.toLower());
        result.push_back(genre);
    }
    return result;
}

// CatalogContentPolicy.swift:374-398 with its map at :478-504: the genres a
// show is known to have when no online metadata names them.
QStringList offlineTvGenres(const QString &showTitle)
{
    static const QHash<QString, QStringList> genreMap{
        {QStringLiteral("american godfathers the five families"),
         {QStringLiteral("Documentary"), QStringLiteral("Crime")}},
        {QStringLiteral("ancient aliens"),
         {QStringLiteral("Documentary"), QStringLiteral("History")}},
        {QStringLiteral("bill nye the science guy"),
         {QStringLiteral("Kids"), QStringLiteral("Family"), QStringLiteral("Documentary")}},
        {QStringLiteral("bluey"),
         {QStringLiteral("Kids"), QStringLiteral("Animation"), QStringLiteral("Family")}},
        {QStringLiteral("captain planet and the planeteers"),
         {QStringLiteral("Kids"), QStringLiteral("Animation"), QStringLiteral("Family"),
          QStringLiteral("Adventure")}},
        {QStringLiteral("fallout"),
         {QStringLiteral("Drama"), QStringLiteral("Action"), QStringLiteral("Science Fiction")}},
        {QStringLiteral("fosters home for imaginary friends"),
         {QStringLiteral("Kids"), QStringLiteral("Animation"), QStringLiteral("Comedy"),
          QStringLiteral("Family")}},
        {QStringLiteral("game of thrones"), {QStringLiteral("Drama"), QStringLiteral("Fantasy")}},
        {QStringLiteral("hey arnold"),
         {QStringLiteral("Kids"), QStringLiteral("Animation"), QStringLiteral("Comedy"),
          QStringLiteral("Family")}},
        {QStringLiteral("holy marvels with dennis quaid"),
         {QStringLiteral("Documentary"), QStringLiteral("History")}},
        {QStringLiteral("hunting hitler"),
         {QStringLiteral("Documentary"), QStringLiteral("History")}},
        {QStringLiteral("joe pera talks with you"), {QStringLiteral("Comedy")}},
        {QStringLiteral("king of the hill"),
         {QStringLiteral("Animation"), QStringLiteral("Comedy")}},
        {QStringLiteral("outlander"), {QStringLiteral("Drama"), QStringLiteral("Romance")}},
        {QStringLiteral("secrets declassified with david duchovny"),
         {QStringLiteral("Documentary"), QStringLiteral("History")}},
        {QStringLiteral("seinfeld"), {QStringLiteral("Comedy")}},
        {QStringLiteral("star trek deep space nine"),
         {QStringLiteral("Science Fiction"), QStringLiteral("Adventure"), QStringLiteral("Drama")}},
        {QStringLiteral("star trek the next generation"),
         {QStringLiteral("Science Fiction"), QStringLiteral("Adventure"), QStringLiteral("Drama")}},
        {QStringLiteral("star trek the original series"),
         {QStringLiteral("Science Fiction"), QStringLiteral("Adventure"), QStringLiteral("Drama")}},
        {QStringLiteral("the magic school bus"),
         {QStringLiteral("Kids"), QStringLiteral("Animation"), QStringLiteral("Family"),
          QStringLiteral("Documentary")}},
        {QStringLiteral("the office us"), {QStringLiteral("Comedy")}},
        {QStringLiteral("the simpsons"), {QStringLiteral("Animation"), QStringLiteral("Comedy")}},
        {QStringLiteral("the why files"),
         {QStringLiteral("Documentary"), QStringLiteral("Mystery")}},
        {QStringLiteral("the x files"),
         {QStringLiteral("Drama"), QStringLiteral("Mystery"), QStringLiteral("Science Fiction")}},
        {QStringLiteral("tuttle twins"),
         {QStringLiteral("Kids"), QStringLiteral("Animation"), QStringLiteral("Family")}}};

    const QString key = offlineLookupKey(showTitle);
    const auto mapped = genreMap.constFind(key);
    if (mapped != genreMap.constEnd()) {
        return *mapped;
    }

    QStringList inferred;
    if (key.contains(QStringLiteral("star trek"))) {
        inferred << QStringLiteral("Science Fiction") << QStringLiteral("Adventure");
    }
    if (key.contains(QStringLiteral("science")) || key.contains(QStringLiteral("history"))
        || key.contains(QStringLiteral("ancient")) || key.contains(QStringLiteral("declassified"))
        || key.contains(QStringLiteral("files"))) {
        inferred << QStringLiteral("Documentary");
    }
    if (key.contains(QStringLiteral("school")) || key.contains(QStringLiteral("kids"))) {
        inferred << QStringLiteral("Kids") << QStringLiteral("Family");
    }
    if (key.contains(QStringLiteral("animated"))) {
        inferred << QStringLiteral("Animation");
    }
    return uniqueGenres(inferred);
}

QStringList offlineMovieGenres(const QString &movieTitle)
{
    static const QStringList animated{
        "abominable", "aladdin", "alvin and the chipmunks", "bambi",
        "beauty and the beast", "bee movie", "big hero 6", "boss baby",
        "brave", "bug s life", "cars", "castle in the sky", "cinderella",
        "coco", "croods", "despicable me", "dumbo", "elemental", "encanto",
        "emperor s new groove", "fantastic mr fox", "finding dory",
        "finding nemo", "frozen", "ice age", "incredibles", "inside out",
        "iron giant", "jungle book", "klaus", "kung fu panda", "lion king",
        "lilo stitch", "little mermaid", "luca", "madagascar", "megamind",
        "minions", "mitchells vs the machines", "moana", "monsters inc",
        "monsters university", "monsters vs aliens", "my neighbor totoro",
        "onward", "over the hedge", "penguins of madagascar",
        "princess mononoke", "puss in boots", "ralph breaks the internet",
        "ratatouille", "rise of the guardians", "shrek", "soul",
        "spirited away", "spirit stallion", "tangled", "the bad guys",
        "the wild robot", "toy story", "treasure planet", "trolls", "turbo",
        "turning red", "up", "wall e", "wallace gromit", "wreck it ralph",
        "zootopia"};
    static const QStringList adventure{
        "alice in wonderland", "aliens in the attic", "borrowers",
        "castle in the sky", "chronicles of narnia", "duma", "escape from",
        "explorers", "goonies", "gulliver", "honey i shrunk",
        "how to train your dragon", "hugo", "indian in the cupboard",
        "jumanji", "mighty joe young", "nim s island", "neverending story",
        "oz the great", "pagemaster", "peter pan", "princess bride",
        "rocketeer", "spy kids", "stardust", "swiss family robinson",
        "the water horse", "treasure planet", "zathura"};
    static const QStringList comedy{
        "alvin and the chipmunks", "baby s day out", "bean", "bee movie",
        "charlie and the chocolate factory", "dennis the menace",
        "despicable me", "elf", "freaky friday", "game plan",
        "home alone", "honey i", "jingle all the way", "little rascals",
        "major payne", "matilda", "minions", "mousehunt", "mr bean",
        "mrs doubtfire", "paddington", "problem child", "richie rich",
        "school of rock", "shrek", "tooth fairy"};
    static const QStringList fantasy{
        "alice in wonderland", "casper", "chronicles of narnia",
        "enchanted", "hocus pocus", "hook", "how the grinch",
        "indian in the cupboard", "lemony snicket", "neverending story",
        "oz the great", "pagemaster", "peter pan", "princess bride",
        "santa clause", "spiderwick", "stardust", "tooth fairy",
        "wizard of oz"};
    static const QStringList scienceFiction{
        "aliens in the attic", "escape from planet earth", "e t",
        "explorers", "iron giant", "megamind", "monsters vs aliens",
        "treasure planet", "wall e", "zathura"};
    static const QStringList sports{
        "cars", "game plan", "hoosiers", "little giants", "sandlot",
        "space jam", "turbo"};
    static const QStringList music{
        "aladdin", "beauty and the beast", "coco", "encanto", "frozen",
        "lion king", "mary poppins", "moana", "music man", "little mermaid",
        "sound of music", "trolls"};
    static const QStringList holiday{
        "christmas", "elf", "frozen", "grinch", "home alone",
        "it s a wonderful life", "jingle all the way", "klaus",
        "santa clause"};
    static const QStringList drama{
        "a little princess", "children of heaven", "free willy", "jack",
        "old yeller", "secondhand lions", "sound of music", "wonder"};

    const QString key = offlineLookupKey(movieTitle);
    QStringList inferred;
    if (containsAny(key, animated)) {
        inferred << QStringLiteral("Animation");
    }
    if (containsAny(key, adventure)) {
        inferred << QStringLiteral("Adventure");
    }
    if (containsAny(key, comedy)) {
        inferred << QStringLiteral("Comedy");
    }
    if (containsAny(key, fantasy)) {
        inferred << QStringLiteral("Fantasy");
    }
    if (containsAny(key, scienceFiction)) {
        inferred << QStringLiteral("Science Fiction");
    }
    if (containsAny(key, sports)) {
        inferred << QStringLiteral("Sports");
    }
    if (containsAny(key, music)) {
        inferred << QStringLiteral("Music");
    }
    if (containsAny(key, holiday)) {
        inferred << QStringLiteral("Holiday");
    }
    if (containsAny(key, drama)) {
        inferred << QStringLiteral("Drama");
    }
    return uniqueGenres(inferred);
}

// CatalogContentPolicy.swift:305-320: the first folder under the root names a
// genre when it is one of the known names; CatalogProjection.swift:481-486
// puts that folder genre ahead of the title-inferred ones.
QString folderGenreOf(const MediaItem &episode)
{
    static const QSet<QString> knownGenres{
        QStringLiteral("action"), QStringLiteral("adventure"), QStringLiteral("animation"),
        QStringLiteral("anime"), QStringLiteral("biography"), QStringLiteral("comedy"),
        QStringLiteral("crime"), QStringLiteral("documentary"), QStringLiteral("drama"),
        QStringLiteral("family"), QStringLiteral("fantasy"), QStringLiteral("film noir"),
        QStringLiteral("history"), QStringLiteral("horror"), QStringLiteral("kids"),
        QStringLiteral("holiday"), QStringLiteral("music"), QStringLiteral("musical"),
        QStringLiteral("mystery"), QStringLiteral("romance"), QStringLiteral("sci-fi"),
        QStringLiteral("science fiction"), QStringLiteral("sport"), QStringLiteral("sports"),
        QStringLiteral("suspense"), QStringLiteral("thriller"), QStringLiteral("war"),
        QStringLiteral("western")};

    const QStringList components =
        episode.relativePath.split(QLatin1Char('/'), Qt::SkipEmptyParts);
    // The genre folder must have something below it besides the file itself.
    if (components.size() < 2) {
        return {};
    }
    const QString first = components.first();
    if (!knownGenres.contains(first.toLower())) {
        return {};
    }
    // Swift's `capitalized` uppercases the first letter of every word, and a
    // hyphen starts a new word ("Sci-Fi").
    QString name = first.toLower();
    bool wordStart = true;
    for (QChar &letter : name) {
        if (wordStart) {
            letter = letter.toUpper();
        }
        wordStart = letter == QLatin1Char(' ') || letter == QLatin1Char('-');
    }
    return name.simplified();
}

QStringList genresOf(const MediaItem &item)
{
    QStringList genres;
    const QString folderGenre = folderGenreOf(item);
    if (!folderGenre.isEmpty()) {
        genres.push_back(folderGenre);
    }
    genres += item.isEpisode() ? offlineTvGenres(item.showName) : offlineMovieGenres(item.title);
    return uniqueGenres(genres);
}

int maturityOf(const MediaItem &item)
{
    using Maturity = ProfileStore::Maturity;

    // MaturityLevel.swift:34-47.
    QSet<QString> genres;
    for (const QString &genre : genresOf(item)) {
        const QString normalized = genre.trimmed().toLower();
        if (!normalized.isEmpty()) {
            genres.insert(normalized);
        }
    }
    const auto hasAny = [&genres](std::initializer_list<const char *> names) {
        return std::any_of(names.begin(), names.end(), [&genres](const char *name) {
            return genres.contains(QLatin1String(name));
        });
    };
    const bool hasFamily = hasAny({"family", "kids & family", "children"});
    const bool hasKidsGenre = hasAny({"kids", "children", "preschool"});
    const bool hasAnimation = hasAny({"animation", "animated"});
    const bool hasMature = hasAny({"horror", "crime", "thriller", "war"});
    const bool kidsSignal = hasKidsGenre || (hasFamily && hasAnimation);

    // MaturityLevel.swift:75-82, the branch without a certification.
    if (genres.isEmpty()) {
        return static_cast<int>(Maturity::Adult);
    }
    if (kidsSignal) {
        return static_cast<int>(Maturity::Kids);
    }
    if (hasFamily) {
        return static_cast<int>(Maturity::Family);
    }
    return static_cast<int>(hasMature ? Maturity::Adult : Maturity::Teen);
}

bool allows(int profileMaturity, const MediaItem &item)
{
    using Maturity = ProfileStore::Maturity;

    // UserProfile.swift:70-79: Adult sees everything; Kids sees up to Family;
    // Family and Teen see up to their own level.
    if (profileMaturity >= static_cast<int>(Maturity::Adult)) {
        return true;
    }
    const int ceiling = profileMaturity <= static_cast<int>(Maturity::Kids)
        ? static_cast<int>(Maturity::Family)
        : profileMaturity;
    return maturityOf(item) <= ceiling;
}

QVector<MediaItem> filtered(int profileMaturity, const QVector<MediaItem> &items)
{
    QVector<MediaItem> allowed;
    allowed.reserve(items.size());
    std::copy_if(items.cbegin(), items.cend(), std::back_inserter(allowed),
                 [profileMaturity](const MediaItem &item) {
                     return allows(profileMaturity, item);
                 });
    return allowed;
}
}
