import { NativeSyntheticEvent, ViewProps } from 'react-native';
export type GenericEmptyEvent = Record<string, never>;
export type StackScreenEventHandler = (event: NativeSyntheticEvent<GenericEmptyEvent>) => void;
export type StackScreenProps = {
    children?: ViewProps['children'];
    maxLifecycleState: 0 | 1 | 2;
    screenKey: string;
    onWillAppear?: StackScreenEventHandler;
    onDidAppear?: StackScreenEventHandler;
    onWillDisappear?: StackScreenEventHandler;
    onDidDisappear?: StackScreenEventHandler;
    onPop?: (screenKey: string) => void;
};
//# sourceMappingURL=StackScreen.types.d.ts.map