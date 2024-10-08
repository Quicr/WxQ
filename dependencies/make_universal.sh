# SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
# SPDX-License-Identifier: BSD-2-Clause

# Univeral binary
DIR="$(cd "$(dirname "$0")";pwd -P)"
ORIGINAL=$(readlink -f $DIR/build-$PREFIX-$BUILD_FOLDER/$TARGET_PATH/$TARGET.framework/$TARGET)
ARCHS=$(lipo -archs $ORIGINAL)
if [ "$ARCHS" == "arm64" ]
then
  lipo -create -output $DIR/$TARGET $ORIGINAL $DIR/build-$PREFIX-x86-$BUILD_FOLDER/$TARGET_PATH/$TARGET.framework/$TARGET
  mv $DIR/$TARGET $ORIGINAL
fi
