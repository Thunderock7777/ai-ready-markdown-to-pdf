@echo off
set /p choice="Do you want to delete all PDF and TXT files in this folder? (y/n): "
if /i "%choice%"=="y" (
    echo Deleting files...
    del *.pdf *.txt *.md *.html
    echo Files successfully deleted.
) else (
    echo Deletion canceled.
)
pause