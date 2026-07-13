import * as React from 'react';
// @ts-ignore file to be used only if `react-native-reanimated` available in the project
import Animated from 'react-native-reanimated';

// Sheet openness in [0,1] (1 = settled open, 0 = dismissed), driven on the UI thread from the native
// onSheetProgress event. undefined when not inside a Native Stack sheet screen.
export default React.createContext<Animated.SharedValue<number> | undefined>(
  undefined,
);
