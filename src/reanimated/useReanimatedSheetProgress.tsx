import * as React from 'react';
// @ts-ignore file to be used only if `react-native-reanimated` available in the project
import { useSharedValue } from 'react-native-reanimated';
import ReanimatedSheetProgressContext from './ReanimatedSheetProgressContext';

// Returns a Reanimated SharedValue tracking sheet openness in [0,1] (1 = settled open, 0 = dismissed),
// updated every frame on the UI thread during the open animation, interactive drag, and dismiss.
// Falls back to a constant 1 SharedValue when not inside a Native Stack sheet screen (no provider),
// so consumers never crash if the screen isn't a sheet.
export default function useReanimatedSheetProgress() {
  const fallback = useSharedValue(1);
  const sheetProgress = React.useContext(ReanimatedSheetProgressContext);
  return sheetProgress ?? fallback;
}
