#pragma once

#include <QString>

struct AppError
{
    QString code;
    QString title;
    QString userMessage;
    QString technicalDetail;
};
