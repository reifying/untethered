import React from 'react';
import { StackScreenProps } from './StackScreen.types';
export declare const StackScreenLifecycleState: {
    readonly INITIAL: 0;
    readonly DETACHED: 1;
    readonly ATTACHED: 2;
};
/**
 * EXPERIMENTAL API, MIGHT CHANGE W/O ANY NOTICE
 */
declare function StackScreen({ children, maxLifecycleState, screenKey, onWillAppear, onWillDisappear, onDidAppear, onDidDisappear, onPop, }: StackScreenProps): React.JSX.Element;
export default StackScreen;
//# sourceMappingURL=StackScreen.d.ts.map