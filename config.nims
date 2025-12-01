
import std/compilesettings

const
  nimLibPath = querySetting(libPath)

task link, "link":
  echo "Library path: ", nimLibPath


