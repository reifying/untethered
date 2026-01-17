import type { CodegenTypes as CT, ViewProps } from 'react-native';
export type GenericEmptyEvent = Readonly<{}>;
export interface NativeProps extends ViewProps {
    maxLifecycleState: CT.Int32;
    screenKey: string;
    onWillAppear?: CT.DirectEventHandler<GenericEmptyEvent>;
    onDidAppear?: CT.DirectEventHandler<GenericEmptyEvent>;
    onWillDisappear?: CT.DirectEventHandler<GenericEmptyEvent>;
    onDidDisappear?: CT.DirectEventHandler<GenericEmptyEvent>;
}
declare const _default: import("react-native").HostComponent<NativeProps>;
export default _default;
//# sourceMappingURL=StackScreenNativeComponent.d.ts.map