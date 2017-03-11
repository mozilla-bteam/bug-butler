use 5.24.0;
use experimental 'signatures';

package BugButler::Config {
    use Moo;
    no warnings 'experimental';

    extends 'Config::GitLike';

    sub dir_file($self) {
        return $self->confname . ".ini";
    }

}
1;
